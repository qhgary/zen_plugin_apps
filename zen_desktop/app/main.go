package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/md5"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	core "zenservice"
)

// AuthResponse 授权验证结果
type AuthResponse struct {
	Valid             bool   `json:"valid"`
	Message           string `json:"message"`
	ExpireStr         string `json:"expire_str"`
	ExpireTs          int64  `json:"expire_ts"`
	Features          uint32 `json:"features"`
	AvailableFeatures string `json:"available_features"`
	User              string `json:"user"`
	IsTrial           bool   `json:"is_trial"`
	DaysLeft          int32  `json:"days_left"`
	ErrorCode         uint32 `json:"error_code"`
}

// needsDialog 判断是否需要弹窗提示
func needsDialog(errorCode uint32) bool {
	return errorCode == 5 || errorCode == 6 || errorCode == 7 || errorCode == 8 || errorCode == 9 || errorCode == 12 || errorCode == 13
}

// showAuthDialog 显示授权错误弹窗（阻塞直到用户点击确定）
func showAuthDialog(message string) {
	var cmd *exec.Cmd

	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("osascript", "-e",
			fmt.Sprintf(`display dialog "%s" buttons {"确定"} default button 1 with icon stop with title "Zen 授权提示"`, message))
	case "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-Command",
			fmt.Sprintf(`Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.MessageBox]::Show("%s", "Zen 授权提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)`, message))
	case "linux":
		if _, err := exec.LookPath("zenity"); err == nil {
			cmd = exec.Command("zenity", "--error", "--text", message, "--title", "Zen 授权提示")
		} else {
			logger.Printf("授权提示: %s (zenity 未安装)", message)
			return
		}
	default:
		logger.Printf("授权提示: %s (不支持的平台)", message)
		return
	}

	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Run() // 阻塞直到用户点击确定
}

// cleanupAndExit 清理资源并退出程序
func cleanupAndExit(code int) {
	logger.Printf("正在清理资源并退出 (code=%d)...", code)

	// 关闭数据源连接
	core.CloseDataSource()

	// 关闭 Go 打开的浏览器
	if browserPID > 0 {
		switch runtime.GOOS {
		case "darwin", "linux":
			exec.Command("kill", "-9", fmt.Sprintf("%d", browserPID)).Run()
			logger.Printf("已关闭浏览器进程 (PID: %d)", browserPID)
		case "windows":
			exec.Command("taskkill", "/F", "/PID", fmt.Sprintf("%d", browserPID)).Run()
		}
	}

	os.Exit(code)
}

// handleAuthDialog 处理授权错误弹窗请求（由浏览器 WASM 层调用）
func handleAuthDialog(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Message    string `json:"message"`
		ErrorCode  uint32 `json:"error_code"`
		ShouldExit bool   `json:"should_exit"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	logger.Printf("授权错误弹窗请求: code=%d, message=%s", req.ErrorCode, req.Message)

	if needsDialog(req.ErrorCode) && !authDialogShown {
		authDialogShown = true
		// 在主线程中显示弹窗（阻塞）
		go func() {
			showAuthDialog(req.Message)
		}()
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "ok",
	})
}

type AuthHelperRequest struct {
	Action     string `json:"action"`
	Nonce      string `json:"nonce,omitempty"`
	AppID      string `json:"app_id,omitempty"`
	Platform   string `json:"platform,omitempty"`
	LicenseKey string `json:"license_key,omitempty"`
}

type AuthHelperResponse struct {
	Success     bool          `json:"success"`
	Message     string        `json:"message"`
	MachineCode string        `json:"machine_code"`
	AuthResult  *AuthResponse `json:"auth_result"`
	Attestation string        `json:"attestation"`
	LicenseKey  string        `json:"license_key,omitempty"`
}

func helperBinaryName() string {
	if runtime.GOOS == "windows" {
		return "zen_auth_helper.exe"
	}
	return "zen_auth_helper"
}

var (
	helperProcess   *exec.Cmd
	helperStdin     io.WriteCloser
	helperStdout    *bufio.Reader
	helperTempDir   string
	helperMu        sync.Mutex
	authDialogShown bool
)

func extractHelperToTemp() (string, error) {
	if len(embeddedHelper) == 0 {
		return "", fmt.Errorf("授权 helper 未嵌入")
	}

	tmpDir, err := os.MkdirTemp("", "zen_auth_*")
	if err != nil {
		return "", fmt.Errorf("创建临时目录失败: %w", err)
	}

	helperPath := filepath.Join(tmpDir, helperBinaryName())
	if err := os.WriteFile(helperPath, embeddedHelper, 0700); err != nil {
		os.RemoveAll(tmpDir)
		return "", fmt.Errorf("写入 helper 失败: %w", err)
	}

	return helperPath, nil
}

func findAuthHelperPath() (string, error) {
	if len(embeddedHelper) > 0 {
		return extractHelperToTemp()
	}

	candidates := make([]string, 0, 5)
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		candidates = append(candidates, filepath.Join(exeDir, helperBinaryName()))
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(cwd, helperBinaryName()),
			filepath.Join(cwd, "..", "..", "..", "target", "debug", helperBinaryName()),
			filepath.Join(cwd, "..", "..", "..", "target", "release", helperBinaryName()),
		)
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("未找到授权 helper，请确认 %s 已部署", helperBinaryName())
}

func startHelperProcessLocked() error {
	if helperProcess != nil && helperProcess.Process != nil {
		return nil
	}

	helperPath, err := findAuthHelperPath()
	if err != nil {
		return err
	}
	debugLog("启动 auth helper: %s", helperPath)

	cmd := exec.Command(helperPath)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("创建 stdin 管道失败: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("创建 stdout 管道失败: %w", err)
	}

	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 helper 失败: %w", err)
	}

	helperProcess = cmd
	helperStdin = stdin
	helperStdout = bufio.NewReader(stdout)

	ready, err := helperStdout.ReadString('\n')
	if err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("等待 helper 就绪信号失败: %w", err)
	}
	if ready != "READY\n" {
		cmd.Process.Kill()
		return fmt.Errorf("helper 就绪信号异常: %q", ready)
	}
	debugLog("auth helper 已就绪")

	if helperPath != "" && len(embeddedHelper) > 0 {
		helperTempDir = filepath.Dir(helperPath)
	}

	return nil
}

func callAuthHelper(request AuthHelperRequest) (*AuthHelperResponse, error) {
	helperMu.Lock()
	defer helperMu.Unlock()

	if helperProcess == nil {
		if err := startHelperProcessLocked(); err != nil {
			return nil, err
		}
	}
	stdin := helperStdin
	stdout := helperStdout

	payload, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}

	debugLog("[Helper] ==> action=%s", request.Action)
	if _, err := stdin.Write(payload); err != nil {
		helperProcess = nil
		helperStdin = nil
		helperStdout = nil
		if startHelperProcessLocked() != nil {
			return nil, fmt.Errorf("写入 helper 失败（helper 重启也失败）: %w", err)
		}
		stdin = helperStdin
		stdout = helperStdout
		if _, err := stdin.Write(payload); err != nil {
			return nil, fmt.Errorf("写入 helper 失败（重试）: %w", err)
		}
		if _, err := stdin.Write([]byte("\n")); err != nil {
			return nil, fmt.Errorf("写入 helper 失败（重试）: %w", err)
		}
	} else {
		if _, err := stdin.Write([]byte("\n")); err != nil {
			return nil, fmt.Errorf("写入 helper 失败: %w", err)
		}
	}

	line, err := stdout.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("读取 helper 响应失败: %w", err)
	}
	debugLog("[Helper] <== response received")

	var response AuthHelperResponse
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		return nil, fmt.Errorf("helper 响应解析失败: %w", err)
	}
	debugLog("[Helper]     success=%v, has_auth_result=%v",
		response.Success, response.AuthResult != nil)
	if response.MachineCode != "" {
		currentMachineID = response.MachineCode
	}
	if !response.Success {
		return &response, fmt.Errorf("%s", response.Message)
	}
	return &response, nil
}

func killHelperProcess() {
	helperMu.Lock()
	defer helperMu.Unlock()

	if helperProcess != nil && helperProcess.Process != nil {
		helperProcess.Process.Kill()
		helperProcess = nil
		helperStdin = nil
		helperStdout = nil
	}
	if helperTempDir != "" {
		os.RemoveAll(helperTempDir)
		helperTempDir = ""
	}
}

func handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "status",
		AppID:    "zen_desktop",
		Platform: "desktop",
	})
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	if resp != nil && resp.AuthResult != nil {
		resp.AuthResult.ErrorCode = core.MapErrorCode(resp.AuthResult.ErrorCode)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func getHelperPublicKeyHex() string {
	return "57ce6d1f495d8fe5d7ece5cbaa6478d69764875c60524465cebc0d2c8f6bacb0"
}

// verifyAttestation 验证 helper 颁发的 attestation，完整校验 nonce + app_id + platform + TTL
func verifyAttestation(attestation string, expectedNonce string, expectedAppID string, expectedPlatform string) error {
	cleanAttestation := strings.TrimSpace(attestation)
	if cleanAttestation == "" {
		return errors.New("缺少证明")
	}

	decoded, err := base64.StdEncoding.DecodeString(cleanAttestation)
	if err != nil {
		return errors.New("证明 Base64 解码失败")
	}

	if len(decoded) < 4+64 {
		return errors.New("证明格式无效")
	}

	payloadLen := int(decoded[0])<<24 | int(decoded[1])<<16 | int(decoded[2])<<8 | int(decoded[3])

	if len(decoded) < 4+payloadLen+64 {
		return errors.New("证明格式无效")
	}

	payloadBytes := decoded[4 : 4+payloadLen]
	signatureBytes := decoded[4+payloadLen : 4+payloadLen+64]

	if len(signatureBytes) != ed25519.SignatureSize {
		return errors.New("证明签名长度无效")
	}

	pubKeyBytes, err := hex.DecodeString(getHelperPublicKeyHex())
	if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
		return errors.New("内置公钥无效")
	}

	if !ed25519.Verify(pubKeyBytes, payloadBytes, signatureBytes) {
		return errors.New("签名校验失败，可能被伪造")
	}

	var payload struct {
		Nonce      string `json:"nonce"`
		AppID      string `json:"app_id"`
		Platform   string `json:"platform"`
		IssuedAtMs int64  `json:"issued_at_ms"`
		TTLMs      int64  `json:"ttl_ms"`
	}
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return errors.New("证明载荷解析失败")
	}

	if payload.Nonce != expectedNonce {
		return errors.New("请求 Nonce 不匹配")
	}

	if payload.AppID != expectedAppID || payload.Platform != expectedPlatform {
		return errors.New("授权证明应用标识不匹配")
	}

	if payload.TTLMs <= 0 || payload.IssuedAtMs <= 0 {
		return errors.New("授权证明时间信息异常")
	}

	nowMs := time.Now().UnixMilli()
	if nowMs > payload.IssuedAtMs+payload.TTLMs {
		return errors.New("授权证明已过期，请重新验证")
	}

	return nil
}

func handleAuthSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Nonce    string `json:"nonce"`
		AppID    string `json:"app_id"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	debugLog("[AuthSession] 开始处理: app_id=%s, platform=%s",
		req.AppID, req.Platform)
	sessionNonce := strings.TrimSpace(req.Nonce)
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "session",
		Nonce:    sessionNonce,
		AppID:    strings.TrimSpace(req.AppID),
		Platform: strings.TrimSpace(req.Platform),
	})
	if err != nil {
		debugLog("[AuthSession] callAuthHelper 失败: %v", err)
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}

	if resp.Success {
		debugLog("[AuthSession] Helper 返回成功，开始验证 attestation...")
		if err := verifyAttestation(resp.Attestation, sessionNonce, req.AppID, req.Platform); err != nil {
			debugLog("[AuthSession] 签名校验失败: %v", err)
			logger.Printf("安全拦截: Auth Helper 签名校验失败 (%v)", err)
			http.Error(w, "安全校验失败", http.StatusForbidden)
			return
		}
		debugLog("[AuthSession] 签名校验通过!")
	} else {
		debugLog("[AuthSession] Helper 返回失败: %s", resp.Message)
	}

	if resp != nil && resp.AuthResult != nil {
		resp.AuthResult.ErrorCode = core.MapErrorCode(resp.AuthResult.ErrorCode)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func saveLicenseViaHelper(licenseKey string) (*AuthHelperResponse, error) {
	return callAuthHelper(AuthHelperRequest{
		Action:     "save_license",
		LicenseKey: licenseKey,
	})
}

func handleAuthLicense(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		LicenseKey string `json:"license_key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.LicenseKey) == "" {
		http.Error(w, "license_key is empty", http.StatusBadRequest)
		return
	}

	resp, err := saveLicenseViaHelper(strings.TrimSpace(req.LicenseKey))
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func getMachineCodeFromHelper() string {
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "status",
		AppID:    "zen_desktop",
		Platform: "desktop",
	})
	if err != nil {
		debugLog("getMachineCodeFromHelper 失败: %v", err)
		return currentMachineID
	}
	if resp != nil && resp.MachineCode != "" {
		return resp.MachineCode
	}
	debugLog("getMachineCodeFromHelper 返回空机器码")
	return currentMachineID
}

//go:embed zen.html ZenLocalService.js StockData.js zen_analysis_worker.js ZenChartDraw.js ZenHQChartCompat.js
//go:embed jscommon
//go:embed pkg
//go:embed license_agreement.html license_agreement.js
var embeddedFiles embed.FS

// openBrowser 打开浏览器 URL
func openBrowser(url string) error {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("open", url)
		err := cmd.Start()
		if err != nil {
			logger.Printf("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
			logger.Printf("已保存浏览器 PID: %d", browserPID)
		}
		return nil
	case "windows":
		// Windows: 使用默认浏览器打开 URL
		cmd := exec.Command("cmd", "/c", "start", url)
		err := cmd.Start()
		if err != nil {
			logger.Printf("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
			debugLog("已保存浏览器 PID: %d", browserPID)
		}
		return nil
	case "linux":
		browsers := []string{"xdg-open", "google-chrome", "firefox", "mozilla"}
		var cmd *exec.Cmd
		var err error
		for _, browser := range browsers {
			cmd = exec.Command(browser, url)
			if err = cmd.Start(); err == nil {
				break
			}
		}
		if err != nil {
			cmd = exec.Command("xdg-open", url)
			err = cmd.Start()
		}
		if err != nil {
			logger.Printf("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd != nil && cmd.Process != nil {
			browserPID = cmd.Process.Pid
			logger.Printf("已保存浏览器 PID: %d", browserPID)
		}
		return nil
	default:
		logger.Printf("Auto-open browser not supported on %s, please open manually", runtime.GOOS)
		return nil
	}
}

const (
	defaultPort = 8888
	defaultFile = "zen.html"
)

var logger *log.Logger
var restartChan = make(chan bool, 1)
var stopChan = make(chan bool, 1)
var currentMachineID string
var _internalFlag string
var _version string
var _author string

var licenseDecisionChan = make(chan int, 1)
var browserPID = 0                      // Go 打开的浏览器进程 PID
var lastLicensePing = time.Now()        // 记录 license 页最后一次 ping 时间（收到第一次 ping 后才启用检测）
var licensePingReceived = false         // 标记是否已收到第一次 ping
var lastMainPagePing = time.Now()       // 记录主页面最后一次 ping 时间（收到第一次 ping 后才启用检测）
var mainPagePingReceived = false        // 标记是否已收到主页面第一次 ping
var serverToken string                  // 本地服务 API 鉴权 Token
var currentServerPort int               // 当前服务运行端口

func debugLog(format string, v ...interface{}) {
	if _internalFlag == "1" {
		logger.Printf(format, v...)
	}
}

func init() {
	logger = log.New(os.Stdout, "[zen_desktop] ", log.LstdFlags|log.Lshortfile)
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		h := md5.Sum([]byte(fmt.Sprintf("%d%d", time.Now().UnixNano(), os.Getpid())))
		serverToken = hex.EncodeToString(h[:])
	} else {
		serverToken = hex.EncodeToString(tokenBytes)
	}
}

func corsHandler(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p := 8888
		if currentServerPort > 0 {
			p = currentServerPort
		}
		w.Header().Set("Access-Control-Allow-Origin", fmt.Sprintf("http://127.0.0.1:%d", p))
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Zen-Token")
		if r.Method == "OPTIONS" {
			return
		}

		reqToken := r.Header.Get("X-Zen-Token")
		if reqToken == "" {
			reqToken = r.URL.Query().Get("token")
		}
		if reqToken != serverToken {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}

		h(w, r)
	}
}

func restartHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("接收到 API 热重启请求...")
	select {
	case restartChan <- true:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{"status": "ok", "message": "Server is restarting..."}`)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintln(w, `{"status": "error", "message": "Server is already in the process of restarting or stopping."}`)
	}
}

func stopHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("接收到 API 关闭请求...")
	select {
	case stopChan <- true:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{"status": "ok", "message": "Server is shutting down..."}`)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintln(w, `{"status": "error", "message": "Server is already in the process of stopping or shutting down."}`)
	}
}

// handleLicenseDecision 处理 license 弹窗的用户决策（同意/取消）
func handleLicenseDecision(w http.ResponseWriter, r *http.Request) {
	debugLog("[LicenseDecision] 请求到来: path=%s, query=%s", r.URL.Path, r.URL.Query())
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	acceptStr := r.URL.Query().Get("accept")
	debugLog("[LicenseDecision] accept=%s", acceptStr)
	if acceptStr == "1" {
		// 用户同意
		select {
		case licenseDecisionChan <- 1:
			debugLog("[LicenseDecision] 已发送 licenseDecisionChan=1")
		default:
		}
		// 调用 helper 保存接受状态
		debugLog("[LicenseDecision] 调用 helper accept_license...")
		resp, err := callAuthHelper(AuthHelperRequest{
			Action: "accept_license",
		})
		if err != nil {
			debugLog("[LicenseDecision] accept_license 失败: %v", err)
		} else {
			debugLog("[LicenseDecision] accept_license 成功: %+v", resp)
		}
		// 重定向到主页面，让同一个浏览器窗口跳转而非关闭再开新窗口
		http.Redirect(w, r, fmt.Sprintf("/?token=%s", serverToken), 302)
		return
	}

	// 用户取消 - 直接退出，不显示任何页面
	select {
	case licenseDecisionChan <- 0:
		debugLog("[LicenseDecision] 已发送 licenseDecisionChan=0")
	default:
	}
	// 返回空白页面，不显示任何内容
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(`<!DOCTYPE html><html><head></head><body></body></html>`))
	// 注意：cleanupAndExit 由主循环 licenseDecisionChan 分支统一处理，不要重复调用
}

func checkLicenseAccepted() bool {
	debugLog("[CheckLicense] 调用 helper check_license...")
	resp, err := callAuthHelper(AuthHelperRequest{
		Action: "check_license",
	})
	if err != nil {
		logger.Printf("检查许可证接受状态失败: %v", err)
		debugLog("[CheckLicense] 失败: %v", err)
		return false
	}
	debugLog("[CheckLicense] resp.Success=%v, resp.Message=%s", resp.Success, resp.Message)
	accepted := resp.Success && resp.Message == "accepted"
	debugLog("[CheckLicense] 结果: %v", accepted)
	return accepted
}

func isPortAvailable(port int) bool {
	address := fmt.Sprintf(":%d", port)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	listener.Close()
	return true
}

func findAvailablePort(specifiedPort int) int {
	if specifiedPort > 0 && specifiedPort < 65536 {
		if isPortAvailable(specifiedPort) {
			logger.Printf("使用指定的端口: %d", specifiedPort)
			return specifiedPort
		}
		logger.Printf("指定的端口 %d 已被占用，回退到默认端口...", specifiedPort)
	}

	if isPortAvailable(defaultPort) {
		logger.Printf("使用默认端口: %d", defaultPort)
		return defaultPort
	}
	logger.Printf("默认端口 %d 也被占用，开始查找可用端口...", defaultPort)

	port := defaultPort + 1
	for port < 65536 {
		if isPortAvailable(port) {
			logger.Printf("找到并使用可用端口: %d", port)
			return port
		}
		port++
	}

	logger.Fatal("未能找到任何可用的TCP端口 (8888-65535)。")
	return -1
}

func getWatchListPath() string {
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		path := filepath.Join(exeDir, "zen_watchlist.json")
		if _, err := os.Stat(path); err == nil {
			return path
		}
		testFile := filepath.Join(exeDir, ".zen_write_test")
		if err := os.WriteFile(testFile, []byte("test"), 0600); err == nil {
			os.Remove(testFile)
			return path
		}
	}

	cwd, _ := os.Getwd()
	return filepath.Join(cwd, "zen_watchlist.json")
}

func getDataSourcePath() string {
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		path := filepath.Join(exeDir, "datasource.json")
		if _, err := os.Stat(path); err == nil {
			return path
		}
		testFile := filepath.Join(exeDir, ".zen_write_test")
		if err := os.WriteFile(testFile, []byte("test"), 0600); err == nil {
			os.Remove(testFile)
			return path
		}
	}

	cwd, _ := os.Getwd()
	return filepath.Join(cwd, "datasource.json")
}

func serveStaticFile(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// WASM 文件从 embedded pkg 读取
	if strings.HasSuffix(path, ".wasm") {
		data, err := embeddedFiles.ReadFile("pkg/" + filepath.Base(path))
		if err != nil {
			logger.Printf("[ERROR] Failed to read embedded wasm: %v", err)
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/wasm")
		w.Write(data)
		return
	}

	// WASM JS 绑定文件从 embedded pkg 读取
	if strings.HasSuffix(path, ".js") && strings.Contains(path, "tdx_zen") {
		data, err := embeddedFiles.ReadFile("pkg/" + filepath.Base(path))
		if err != nil {
			logger.Printf("[ERROR] Failed to read embedded js: %v", err)
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/javascript")
		w.Write(data)
		return
	}

	http.FileServer(http.FS(embeddedFiles)).ServeHTTP(w, r)
}

func main() {
	specifiedPort := flag.Int("port", 0, "Set server port. Overrides default behavior if available.")
	autoOpenBrowser := flag.Bool("open", true, "Auto-open browser. Use -open=false to disable.")

	flag.Parse()

	// 1. 设置工作目录
	exePath, err := os.Executable()
	if err != nil {
		log.Fatalf("Failed to get executable path: %v", err)
	}
	workDir := filepath.Dir(exePath)
	os.Chdir(workDir)

	port := findAvailablePort(*specifiedPort)
	currentServerPort = port

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	isFirstRun := true
	// 异步获取初始机器码，避免阻塞启动流程
	go func() {
		currentMachineID = getMachineCodeFromHelper()
	}()

Loop:
	for {
		mux := http.NewServeMux()
		watchListPath := getWatchListPath()
		datasourcePath := getDataSourcePath()
		core.InitDataSource(datasourcePath)
		core.RegisterAPIServer(mux, core.APIOptions{
			MachineCode: func() string {
				return getMachineCodeFromHelper()
			},
			SaveLicense: func(licenseKey string) error {
				_, err := saveLicenseViaHelper(licenseKey)
				return err
			},
			EnableLicenseAPI: false,
			WatchListPath:    watchListPath,
			DebugMode:        _internalFlag == "1",
			AuthToken:        serverToken,
			AllowedOrigin:    fmt.Sprintf("http://127.0.0.1:%d", currentServerPort),
		})
		mux.HandleFunc("/api/restart", corsHandler(restartHandler))
		mux.HandleFunc("/api/stop", corsHandler(stopHandler))
		mux.HandleFunc("/api/auth_dialog", corsHandler(handleAuthDialog))
		mux.HandleFunc("/api/auth/status", corsHandler(handleAuthStatus))
		mux.HandleFunc("/api/auth/session", corsHandler(handleAuthSession))
		mux.HandleFunc("/api/auth/license", corsHandler(handleAuthLicense))

		mux.HandleFunc("/license-ping", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			lastLicensePing = time.Now()
			if !licensePingReceived {
				licensePingReceived = true
				debugLog("First ping received, detection now active")
			}
			w.WriteHeader(http.StatusNoContent)
		}))

		mux.HandleFunc("/main-ping", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			lastMainPagePing = time.Now()
			if !mainPagePingReceived {
				mainPagePingReceived = true
				debugLog("Main page first ping received, detection now active")
			}
			w.WriteHeader(http.StatusNoContent)
		}))

		mux.HandleFunc("/license", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			file, err := embeddedFiles.ReadFile("license_agreement.html")
			if err != nil {
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				debugLog("[License] Failed to read license_agreement.html: %v", err)
				return
			}
			debugLog("Serving license page, size=%d bytes", len(file))
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write(file)
		}))

		// License 决策路由（用于阻塞等待场景）
		mux.HandleFunc("/license-decision", handleLicenseDecision)

		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" || r.URL.Path == "" {
				// 仅当首次检查未通过且来自 license 弹窗的跳转时才显示 license
				// 通过 query 参数 from_license=1 标识
				if !checkLicenseAccepted() && r.URL.Query().Get("from_license") != "1" {
					file, err := embeddedFiles.ReadFile("license_agreement.html")
					if err != nil {
						http.Error(w, "Internal Server Error", http.StatusInternalServerError)
						logger.Printf("Error reading embedded license_agreement.html: %v", err)
						return
					}
					w.Header().Set("Content-Type", "text/html; charset=utf-8")
					w.Write(file)
					return
				}
				file, err := embeddedFiles.ReadFile(defaultFile)
				if err != nil {
					http.Error(w, "Internal Server Error", http.StatusInternalServerError)
					logger.Printf("Error reading embedded zen.html: %v", err)
					return
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.Write(file)
				return
			}
			serveStaticFile(w, r)
		})

		server := &http.Server{
			Addr:           fmt.Sprintf(":%d", port),
			ReadTimeout:    30 * time.Second,
			WriteTimeout:   30 * time.Second,
			MaxHeaderBytes: 1 << 20,
			Handler:        mux,
		}

		serverReady := make(chan struct{})

		go func() {
			logger.Printf("服务器正在启动...")

			addr := fmt.Sprintf(":%d", port)
			ln, err := net.Listen("tcp", addr)
			if err != nil {
				logger.Fatalf("启动服务器失败: %v", err)
				return
			}

			// 端口监听成功，立即释放信号，无需延迟
			close(serverReady)

			logger.Printf("✅ 服务器监听成功，地址: %s", addr)

			if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
				logger.Fatalf("服务器运行错误: %v", err)
			}
		}()

		if isFirstRun && *autoOpenBrowser {
			// 等待服务器就绪信号
			select {
			case <-serverReady:
				// OK
			case <-time.After(2 * time.Second):
				logger.Printf("警告: 服务器就绪超时")
			}

			// 检查是否需要显示 license 弹窗
			if !checkLicenseAccepted() {
				logger.Printf("检测到用户尚未同意许可证协议，显示弹窗...")

				// 打开 license 页面
				licenseUrl := fmt.Sprintf("http://127.0.0.1:%d/license?token=%s", port, serverToken)
				if err := openBrowser(licenseUrl); err == nil {
					logger.Printf("已打开 license 弹窗，等待用户决策...")
				}
				// 重置 ping 计时器，浏览器打开后等待 JS 加载完成（收到第一次 ping 后才启用检测）
				lastLicensePing = time.Now()
				licensePingReceived = false
				debugLog("浏览器已打开，等待第一次 ping...")

				// 阻塞等待用户决策
				pingTicker := time.NewTicker(500 * time.Millisecond)
				defer pingTicker.Stop()
			licenseLoop:
				for {
					select {
					case decision := <-licenseDecisionChan:
						if decision == 0 {
							logger.Printf("用户取消 license，程序退出")
							killHelperProcess()
							cleanupAndExit(1)
							break
						}
						logger.Printf("用户已同意 license，继续启动...")
						break licenseLoop
					case <-pingTicker.C:
						if licensePingReceived {
							since := time.Since(lastLicensePing)
							if since > 5*time.Second {
								logger.Printf("检测到 license 弹窗已关闭（超时 5s 未收到 Ping），程序退出")
								killHelperProcess()
								cleanupAndExit(1)
								break
							}
						}
					case <-time.After(10 * 60 * time.Second):
						logger.Printf("License 弹窗超时，程序退出")
						killHelperProcess()
						cleanupAndExit(1)
						break
					}
				}
			}

			url := fmt.Sprintf("http://127.0.0.1:%d/?token=%s", port, serverToken)

			logger.Printf("")
			logger.Printf("========================================")
			logger.Printf("  禅中看缠桌面版")
			logger.Printf("========================================")
			logger.Printf("本地访问: http://127.0.0.1:%d/", port)
			logger.Printf("========================================")
			logger.Printf("")

			if err := openBrowser(url); err == nil {
				logger.Printf("已自动打开浏览器")
			}
			// 重置主页面 ping 计时器，等待 JS 页面加载完成后首次 ping
			lastMainPagePing = time.Now()
			mainPagePingReceived = false
			isFirstRun = false
		}

		// 主页面存活检测：每 500ms 检查一次 ping 超时
		mainPingTicker := time.NewTicker(500 * time.Millisecond)
		defer mainPingTicker.Stop()

		var shouldRestart bool
		var shutdownReason string

	mainLoop:
		for {
			select {
			case sig := <-quit:
				shutdownReason = fmt.Sprintf("OS signal %v", sig)
				shouldRestart = false
				break mainLoop
			case <-restartChan:
				shutdownReason = "API /restart"
				shouldRestart = true
				break mainLoop
			case <-stopChan:
				shutdownReason = "API /stop"
				shouldRestart = false
				break mainLoop
			case <-mainPingTicker.C:
				if mainPagePingReceived && time.Since(lastMainPagePing) > 5*time.Second {
					logger.Printf("检测到主页面已关闭（超时 5s 未收到 Ping），程序退出")
					killHelperProcess()
					cleanupAndExit(0)
				}
			}
		}

		logger.Printf("接收到指令 (来源: %s). 准备关闭服务器...", shutdownReason)

		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			logger.Printf("服务器关闭失败: %v", err)
		} else {
			logger.Println("服务器已优雅关闭。")
		}

		killHelperProcess()

		if shouldRestart {
			logger.Println("正在热重启服务器...")
			continue Loop
		}

		break Loop
	}
	logger.Println("服务器进程已退出。")
}
