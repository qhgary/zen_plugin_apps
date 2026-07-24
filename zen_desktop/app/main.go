package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
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
		hideWindowSysProcAttr(cmd)
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
			cmd := exec.Command("taskkill", "/F", "/PID", fmt.Sprintf("%d", browserPID))
			hideWindowSysProcAttr(cmd)
			cmd.Run()
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

// getLicenseFilePath 返回 license 文件的持久存储路径
// 优先使用 exe 同级目录，如果不可写则使用用户配置目录
func getLicenseFilePath() string {
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		path := filepath.Join(exeDir, "zen_license.key")
		if _, err := os.Stat(path); err == nil {
			return path
		}
		testFile := filepath.Join(exeDir, ".zen_write_test")
		if err := os.WriteFile(testFile, []byte("test"), 0600); err == nil {
			os.Remove(testFile)
			return path
		}
	}

	// exe 目录不可写，使用用户配置目录
	configDir, err := os.UserConfigDir()
	if err == nil {
		zenDir := filepath.Join(configDir, "zen")
		if mkErr := os.MkdirAll(zenDir, 0700); mkErr != nil {
			logger.Printf("警告: 创建授权目录失败 %s: %v, 回退到 cwd", zenDir, mkErr)
			return "zen_license.key"
		}
		return filepath.Join(zenDir, "zen_license.key")
	}

	// 最终回退到 cwd
	return "zen_license.key"
}

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
	if err := verifyHelperIntegrity(helperPath); err != nil {
		return err
	}
	debugLog("启动 auth helper: %s", helperPath)

	// 修订 1: 每次启动 helper 时生成新的 32 字节握手密钥。
	// helper 启动后通过 ZEN_HANDSHAKE_KEY 环境变量读取；helper 重启时
	// 复用同一 key 以保持与 Go 端状态一致（callAuthHelper 失败重试
	// 路径会调用本函数，但 handshakeSharedKeyHex 全局变量保持）。
	if handshakeSharedKeyHex == "" {
		handshakeSharedKeyHex = hex.EncodeToString(generateHandshakeSharedKey())
		debugLog("已生成本次会话握手密钥 (32B)")
	}

	if !filepath.IsAbs(helperPath) {
		return fmt.Errorf("helper 路径必须为绝对路径: %s", helperPath)
	}
	cleanPath := filepath.Clean(helperPath)
	cmd := exec.Command(cleanPath) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	setupHelperSysProcAttr(cmd)
	cmd.Env = append(os.Environ(),
		"ZEN_LICENSE_PATH="+getLicenseFilePath(),
		"ZEN_HANDSHAKE_KEY="+handshakeSharedKeyHex,
	)
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

	// === 双向认证握手 (修订 2: 加上 pid 字段，helper 会读取调用方进程路径验证身份) ===
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("生成握手 nonce 失败: %w", err)
	}
	hmacSig := computeHandshakeHMAC(nonce)

	handshakeReq := map[string]interface{}{
		"action": "handshake",
		"nonce":  hex.EncodeToString(nonce),
		"hmac":   hex.EncodeToString(hmacSig),
		"pid":    os.Getpid(),
	}
	handshakeJSON, err := json.Marshal(handshakeReq)
	if err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("序列化握手请求失败: %w", err)
	}

	if _, err := stdin.Write(handshakeJSON); err != nil { // nosemgrep: go.lang.security.audit.dangerous-command-write.dangerous-command-write
		cmd.Process.Kill()
		return fmt.Errorf("发送握手请求失败: %w", err)
	}
	if _, err := stdin.Write([]byte("\n")); err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("发送握手换行失败: %w", err)
	}

	// 等待 helper 响应: READY 或 REJECT
	ready, err := helperStdout.ReadString('\n')
	if err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("等待 helper 握手响应失败: %w", err)
	}
	ready = strings.TrimSpace(ready)
	if ready != "READY" {
		cmd.Process.Kill()
		// 修订 1: 区分 REJECT_KEY_MISSING 与普通 REJECT 以便排错
		if strings.HasPrefix(ready, "REJECT_KEY_MISSING") {
			return fmt.Errorf("helper 拒绝启动: 握手密钥未注入 (修订 1 部署异常)")
		}
		return fmt.Errorf("helper 握手验证失败: %q (期望 READY)", ready)
	}
	debugLog("auth helper 握手验证通过，已就绪")

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

	payload, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}

	// 尝试发送请求并读取响应，失败时重启 helper 重试一次
	for attempt := 0; attempt < 2; attempt++ {
		stdin := helperStdin
		stdout := helperStdout

		debugLog("[Helper] ==> action=%s (attempt=%d)", request.Action, attempt+1)
		if _, err := stdin.Write(payload); err != nil {
			debugLog("[Helper] stdin write failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入 helper 失败（helper 重启也失败）: %w", err)
			}
			continue
		}
		if _, err := stdin.Write([]byte("\n")); err != nil {
			debugLog("[Helper] stdin newline write failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入 helper 失败（helper 重启也失败）: %w", err)
			}
			continue
		}

		line, err := stdout.ReadString('\n')
		if err != nil {
			debugLog("[Helper] stdout read failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("读取 helper 响应失败（helper 重启也失败）: %w", err)
			}
			continue
		}
		debugLog("[Helper] <== response received")

		var response AuthHelperResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			debugLog("[Helper] json unmarshal failed: %v, line=%q", err, line)
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

	return nil, fmt.Errorf("helper 通信失败（已重试）")
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
	return "647f4289b670e31476fc7134cf6472fd8e08de5d5aa18ed64f115d8fd3e4d63a"
}

// generateHandshakeSharedKey 生成 32 字节随机握手密钥并返回 hex 编码。
//
// 安全说明 (修订 1)：原实现把 HK1..HK4 4 段 XOR 数组同时硬编码在 Go 源码与
// Rust helper 闭源二进制中，攻击者从公开 Go 源码即可还原 32 字节 shared key
// 然后伪造 HMAC 握手 → helper 颁发合法 attestation → 绕过整条授权链。
// 改为每次启动 helper 时由 Go 端用 crypto/rand 生成 32 字节随机密钥，
// 通过 ZEN_HANDSHAKE_KEY 环境变量注入 helper；helper 启动校验该变量缺失
// 或格式错误则输出 REJECT_KEY_MISSING 拒绝服务。攻击者无法再从源码还原
// 密钥（每次启动都不同），也无法预计算注入 helper（密钥只对当前进程有效）。
func generateHandshakeSharedKey() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		// crypto/rand 失败是致命错误，直接退出
		logger.Fatalf("生成握手密钥失败: %v", err)
	}
	return key
}

// handshakeSharedKeyHex 当前会话握手密钥的 hex 编码（全局状态）。
// 启动 helper 时分配一次，helper 重启时复用同一 key（避免 Go 端持有
// 多份密钥而 helper 已重启导致握手失败）。
var handshakeSharedKeyHex string

// computeHandshakeHMAC 计算握手 HMAC-SHA256 签名
func computeHandshakeHMAC(nonce []byte) []byte {
	key, err := hex.DecodeString(handshakeSharedKeyHex)
	if err != nil || len(key) != 32 {
		logger.Fatalf("握手密钥未初始化或格式错误: %v", err)
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(nonce)
	return mac.Sum(nil)
}

// verifyHelperIntegrity 校验 helper 二进制完整性
func verifyHelperIntegrity(helperPath string) error {
	if expectedHelperSHA256 == "" {
		return nil
	}
	data, err := os.ReadFile(helperPath)
	if err != nil {
		return fmt.Errorf("read helper: %w", err)
	}
	h := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(h[:]), expectedHelperSHA256) {
		return fmt.Errorf("helper integrity check failed")
	}
	return nil
}

// verifyAttestation 验证 helper 颁发的 attestation
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

//go:embed zen.html ZenLocalService.js StockData.js zen_analysis_worker.js ZenChartDraw.js ZenHQChartCompat.js ZenStockSearch.js
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
		hideWindowSysProcAttr(cmd)
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
			cmd = exec.Command(browser, url) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
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
var expectedHelperSHA256 string

var licenseDecisionChan = make(chan int, 1)
var browserPID = 0                // Go 打开的浏览器进程 PID
var lastLicensePing = time.Now()  // 记录 license 页最后一次 ping 时间（收到第一次 ping 后才启用检测）
var licensePingReceived = false   // 标记是否已收到第一次 ping
var lastMainPagePing = time.Now() // 记录主页面最后一次 ping 时间（收到第一次 ping 后才启用检测）
var mainPagePingReceived = false  // 标记是否已收到主页面第一次 ping
var serverToken string            // 本地服务 API 鉴权 Token
var currentServerPort int         // 当前服务运行端口

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
		// 反射请求的 Origin：服务只监听 loopback，浏览器可能因 hosts / 代理
		// 把 127.0.0.1 改写成 localhost（或反之），硬写一个值会触发 WebKit
		// 的 "TypeError: Load failed"。反射回请求的 Origin 是最稳的本地 CORS 写法。
		// 同源请求不发送 Origin 头时（大多数情况），反射自然不写任何 CORS 头，
		// 同源也不需要 CORS 头。
		if origin := r.Header.Get("Origin"); origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
		}
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

// checkIAgreeFile 检查 exe 同目录下是否存在 I_agree 开头的文件（不区分大小写，任意扩展名）
func checkIAgreeFile() bool {
	exePath, err := os.Executable()
	if err != nil {
		return false
	}
	exeDir := filepath.Dir(exePath)
	entries, err := os.ReadDir(exeDir)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if len(name) >= 7 && strings.EqualFold(name[:7], "i_agree") {
			return true
		}
	}
	return false
}

// acceptLicenseViaIAgreeFile 检测到 I_agree 文件后代为执行用户同意协议的完整流程
func acceptLicenseViaIAgreeFile() bool {
	logger.Printf("检测到 I_agree 文件，视同用户已同意许可证协议")
	resp, err := callAuthHelper(AuthHelperRequest{
		Action: "accept_license",
	})
	if err != nil {
		logger.Printf("I_agree 文件: accept_license 失败: %v", err)
		return false
	}
	debugLog("[IAgree] accept_license 结果: %+v", resp)
	return true
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

	// 校验 helper 完整性
	if expectedHelperSHA256 == "" {
		// debug 手动编译通常没注入 SHA256，改为警告而不是拒绝启动，
		// 避免开发时每次都要算 SHA256 才能跑。release 构建走 build.sh/build.bat 注入。
		logger.Printf("⚠️ helper integrity 未配置: 以未校验模式启动 (debug/手动编译常见)。" +
			"release 请通过 build.sh / build.bat 注入 expectedHelperSHA256。")
	} else if helperPath, err := findAuthHelperPath(); err == nil {
		if err := verifyHelperIntegrity(helperPath); err != nil {
			logger.Fatalf("helper integrity check failed: %v", err)
		}
	}

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
			WatchListPath: watchListPath,
			DebugMode:     _internalFlag == "1",
			AuthToken:     serverToken,
			AllowedOrigin: fmt.Sprintf("http://127.0.0.1:%d", currentServerPort),
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
		mux.HandleFunc("/license-decision", corsHandler(handleLicenseDecision))

		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" || r.URL.Path == "" {
				// 关键修复：license_agreement.js 的 fetch 在 302 重定向后会 CORS 检查
				// 目标响应（/ 路由）。如果根路由没有 CORS 头，浏览器会把 origin 标记为
				// tainted（WebKit 行为），导致同源 saveLicense 后续也以
				// "TypeError: Load failed" 失败。给 HTML 响应补上 CORS 头即可。
				// 反射 Origin（与 corsHandler 一致），避免 127.0.0.1 / localhost 漂移。
				// DLL 不走 desktop server，本改动不影响 DLL。
				if origin := r.Header.Get("Origin"); origin != "" {
					w.Header().Set("Access-Control-Allow-Origin", origin)
					w.Header().Set("Vary", "Origin")
				}
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Zen-Token")
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

			// 关键修复：首次运行 + 显示过 license 弹窗时，license 页面 fetch 成功后
			// 会用 window.location.replace 直接把自己导航到主页面（见
			// docs/license_agreement.js 的 .then 路径），所以 server 这里不能再
			// openBrowser，否则会重复打开一个主页面 tab。openBrowser 在 Windows
			// 上对带 ?token=... 的 URL 也很不可靠 (cmd /c start 静默失败)。
			licenseShown := false

			// 检查是否需要显示 license 弹窗
			if !checkLicenseAccepted() {
				// 检查 exe 同目录下是否存在 I_agree 文件，视同用户已同意
				if checkIAgreeFile() && acceptLicenseViaIAgreeFile() {
					logger.Printf("I_agree 文件检测完成，跳过协议弹窗")
				} else {
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
							licenseShown = true
							break licenseLoop
						case <-pingTicker.C:
							if licensePingReceived {
								since := time.Since(lastLicensePing)
								if since > 30*time.Second {
									logger.Printf("检测到 license 弹窗已关闭（超时 30s 未收到 Ping），程序退出")
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
			}

			url := fmt.Sprintf("http://127.0.0.1:%d/?token=%s", port, serverToken)

			logger.Printf("")
			logger.Printf("========================================")
			logger.Printf("  禅中看缠桌面版")
			logger.Printf("========================================")
			logger.Printf("本地访问: http://127.0.0.1:%d/", port)
			logger.Printf("========================================")
			logger.Printf("")

			// 只有没显示过 license 弹窗时才需要 server 端主动 openBrowser
			// (例如 restart 后直接进主页面；或 autoOpenBrowser=false 时的"提示用户手动打开"模式)
			if !licenseShown {
				if err := openBrowser(url); err == nil {
					logger.Printf("已自动打开浏览器")
				}
			} else {
				// 这条日志是 license_agreement.js 自行 replace 到主页面路径的副产物，
				// 仅在调试/排查"license 后是否开了重复 tab"时有意义；release 不输出。
				debugLog("license 弹窗已自行导航到主页面，跳过 openBrowser 避免重复")
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
				if mainPagePingReceived && time.Since(lastMainPagePing) > 60*time.Second {
					logger.Printf("检测到主页面已关闭（超时 60s 未收到 Ping），程序退出")
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
