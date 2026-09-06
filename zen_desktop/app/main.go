package main

import (
	"bufio"
	"bytes"
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
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	core "zenservice"
)

// maxBodyBytes 限制 HTTP 请求体大小，防止恶意超大请求耗尽内存
const maxBodyBytes = 1 << 20 // 1MB

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

// needsDialog 判断是否需要弹窗提示（基于公共错误码）
// 原生对话框仅在以下场景需要：
//   1. 协议展示页面用户未点击同意就关闭（license_agreement.js 处理）
//   2. 主界面发现后台被停止/中断（前端 _showSSEErrorDialog 处理）
// 其余授权错误不需要弹原生对话框，授权面板的 errMsg 显示已足够。
func needsDialog(errorCode uint32) bool {
	_ = errorCode
	return false
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
			logger("授权提示: %s (zenity 未安装)", message)
			return
		}
	default:
		logger("授权提示: %s (不支持的平台)", message)
		return
	}

	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Run() // 阻塞直到用户点击确定
}

// cleanupAndExit 清理资源并退出程序
func cleanupAndExit(code int) {
	logger("正在清理资源并退出 (code=%d)...", code)

	// 关闭数据源连接
	core.CloseDataSource()

	// 关闭 Go 打开的浏览器
	if browserPID > 0 {
		switch runtime.GOOS {
		case "darwin", "linux":
			exec.Command("kill", "-9", fmt.Sprintf("%d", browserPID)).Run()
			logger("已关闭浏览器进程 (PID: %d)", browserPID)
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
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Message    string `json:"message"`
		ErrorCode  uint32 `json:"error_code"`
		ShouldExit bool   `json:"should_exit"`
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "请求格式无效", http.StatusBadRequest)
		return
	}

	logger("授权错误弹窗请求: code=%d, message=%s", req.ErrorCode, req.Message)

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
			logger("警告: 创建授权目录失败 %s: %v, 回退到 cwd", zenDir, mkErr)
			return "zen_license.key"
		}
		return filepath.Join(zenDir, "zen_license.key")
	}

	// 最终回退到 cwd
	return "zen_license.key"
}

func extractHelperToTemp() (string, error) {
	if len(embeddedHelper) == 0 {
		return "", fmt.Errorf("认证模块未嵌入")
	}
	// 固定路径 per 程序类型，避免多次运行产生临时文件残留。
	// DLL 用 zen_auth_dll/，Replay 用 zen_auth_replay/，Desktop 用 zen_auth_desktop/。
	tempDir := filepath.Join(os.TempDir(), "zen_auth_desktop")
	if err := os.MkdirAll(tempDir, 0700); err != nil {
		return "", fmt.Errorf("创建临时目录失败: %w", err)
	}
	helperPath := filepath.Join(tempDir, helperBinaryName())

	// 完整性校验：如果已有 helper 且 SHA256 匹配，直接复用，避免重复写入
	if info, err := os.Stat(helperPath); err == nil && !info.IsDir() {
		if info.Size() == int64(len(embeddedHelper)) {
			if existing, err := os.ReadFile(helperPath); err == nil {
				existingHash := sha256.Sum256(existing)
				embeddedHash := sha256.Sum256(embeddedHelper)
				if bytes.Equal(existingHash[:], embeddedHash[:]) {
					return helperPath, nil // 复用已有 helper
				}
			}
		}
	}

	if err := os.WriteFile(helperPath, embeddedHelper, 0700); err != nil {
		return "", fmt.Errorf("写入认证模块失败: %w", err)
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
	return "", fmt.Errorf("未找到认证模块，请确认 %s 已部署", helperBinaryName())
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
	logger("启动 auth helper: %s", helperPath)

	// 修订 1: 每次启动 helper 时生成新的 32 字节握手密钥。
	// helper 启动后通过 ZEN_HANDSHAKE_KEY 环境变量读取；helper 重启时
	// 复用同一 key 以保持与 Go 端状态一致（callAuthHelper 失败重试
	// 路径会调用本函数，但 handshakeSharedKeyHex 全局变量保持）。
	if handshakeSharedKeyHex == "" {
		handshakeSharedKeyHex = hex.EncodeToString(generateHandshakeSharedKey())
		logger("已生成本次会话握手密钥 (32B)")
	}

	cmd := exec.Command(helperPath)
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
		return fmt.Errorf("启动认证模块失败: %w", err)
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

	if _, err := stdin.Write(handshakeJSON); err != nil {
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
		return fmt.Errorf("等待认证模块响应失败: %w", err)
	}
	ready = strings.TrimSpace(ready)
	if ready != "READY" {
		cmd.Process.Kill()
		// 修订 1: 区分 REJECT_KEY_MISSING 与普通 REJECT 以便排错
		if strings.HasPrefix(ready, "REJECT_KEY_MISSING") {
			return fmt.Errorf("认证模块拒绝启动: 握手密钥未注入 (部署异常)")
		}
		return fmt.Errorf("认证模块握手验证失败: %q (期望 READY)", ready)
	}
	logger("auth helper 握手验证通过，已就绪")

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

		logger("[Helper] ==> action=%s (attempt=%d)", request.Action, attempt+1)
		if _, err := stdin.Write(payload); err != nil {
			logger("[Helper] stdin write failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入认证模块失败（重启也失败）: %w", err)
			}
			continue
		}
		if _, err := stdin.Write([]byte("\n")); err != nil {
			logger("[Helper] stdin newline write failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入认证模块失败（重启也失败）: %w", err)
			}
			continue
		}

		line, err := stdout.ReadString('\n')
		if err != nil {
			logger("[Helper] stdout read failed: %v, restarting helper", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("读取认证模块响应失败（重启也失败）: %w", err)
			}
			continue
		}
		logger("[Helper] <== response received")

		var response AuthHelperResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			logger("[Helper] json unmarshal failed: %v, line=%q", err, line)
			return nil, fmt.Errorf("认证模块响应解析失败: %w", err)
		}
		logger("[Helper]     success=%v, has_auth_result=%v",
			response.Success, response.AuthResult != nil)
		if response.MachineCode != "" {
			currentMachineID = response.MachineCode
		}
		if !response.Success {
			return &response, fmt.Errorf("%s", response.Message)
		}
		return &response, nil
	}

	return nil, fmt.Errorf("认证模块通信失败（已重试）")
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
}

func handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
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
		log.Fatalf("生成握手密钥失败: %v", err)
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
		log.Fatalf("握手密钥未初始化或格式错误: %v", err)
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
		return fmt.Errorf("访问认证模块失败: %w", err)
	}
	h := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(h[:]), expectedHelperSHA256) {
		return fmt.Errorf("认证模块完整性校验失败")
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
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Nonce    string `json:"nonce"`
		AppID    string `json:"app_id"`
		Platform string `json:"platform"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "请求格式无效", http.StatusBadRequest)
		return
	}

	logger("[AuthSession] 开始处理: app_id=%s, platform=%s",
		req.AppID, req.Platform)
	sessionNonce := strings.TrimSpace(req.Nonce)
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "session",
		Nonce:    sessionNonce,
		AppID:    strings.TrimSpace(req.AppID),
		Platform: strings.TrimSpace(req.Platform),
	})
	if err != nil {
		logger("[AuthSession] callAuthHelper 失败: %v", err)
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}

	if resp.Success {
		logger("[AuthSession] Helper 返回成功，开始验证 attestation...")
		if err := verifyAttestation(resp.Attestation, sessionNonce, req.AppID, req.Platform); err != nil {
			logger("[AuthSession] 签名校验失败: %v", err)
			logger("安全拦截: Auth Helper 签名校验失败 (%v)", err)
			http.Error(w, "安全校验失败", http.StatusForbidden)
			return
		}
		logger("[AuthSession] 签名校验通过!")
	} else {
		logger("[AuthSession] Helper 返回失败: %s", resp.Message)
	}

	// session 端点不需要返回 license_key（仅用于初始授权检查）
	if resp != nil {
		resp.LicenseKey = ""
		if resp.AuthResult != nil {
			resp.AuthResult.ErrorCode = core.MapErrorCode(resp.AuthResult.ErrorCode)
		}
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
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		LicenseKey string `json:"license_key"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "请求格式无效", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(req.LicenseKey) == "" {
		http.Error(w, "授权码不能为空", http.StatusBadRequest)
		return
	}

	resp, err := saveLicenseViaHelper(strings.TrimSpace(req.LicenseKey))
	// helper 返回了 response（即使 success=false，如授权码无效），
	// 应返回 200 + JSON 让前端读取 auth_result 和 message；
	// 只有 resp==nil（helper 通信失败）才返回 503。
	if err != nil && resp == nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	if resp != nil {
		resp.LicenseKey = ""
		if resp.AuthResult != nil {
			resp.AuthResult.ErrorCode = core.MapErrorCode(resp.AuthResult.ErrorCode)
		}
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
		logger("getMachineCodeFromHelper 失败: %v", err)
		return currentMachineID
	}
	if resp != nil && resp.MachineCode != "" {
		return resp.MachineCode
	}
	logger("getMachineCodeFromHelper 返回空机器码")
	return currentMachineID
}

//go:embed zen.html ZenLocalService.js StockData.js zen_analysis_worker.js ZenChartDraw.js ZenHQChartCompat.js ZenStockSearch.js zen_error_codes.js
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
			logger("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
			logger("已保存浏览器 PID: %d", browserPID)
		}
		return nil
	case "windows":
		// Windows: 使用默认浏览器打开 URL
		// cmd /c start 的第一个引号参数会被解析为窗口标题（可空），
		// URL 中含有 ? 和 = 时必须用引号包裹，否则 cmd 会把 query
		// string 拆成额外参数，导致浏览器打开的 URL 不完整。
		cmd := exec.Command("cmd", "/c", "start", "", url)
		hideWindowSysProcAttr(cmd)
		err := cmd.Start()
		if err != nil {
			logger("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
			logger("已保存浏览器 PID: %d", browserPID)
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
			logger("无法自动打开浏览器，请手动在浏览器中访问: %s", url)
			return err
		}
		if cmd != nil && cmd.Process != nil {
			browserPID = cmd.Process.Pid
			logger("已保存浏览器 PID: %d", browserPID)
		}
		return nil
	default:
		logger("Auto-open browser not supported on %s, please open manually", runtime.GOOS)
		return nil
	}
}

const (
	defaultPort = 8888
	defaultFile = "zen.html"
)

var restartChan = make(chan bool, 1)
var stopChan = make(chan bool, 1)
var currentMachineID string
var _internalFlag string
var expectedHelperSHA256 string

var licenseDecisionChan = make(chan int, 1)
var browserPID = 0                     // Go 打开的浏览器进程 PID
var licenseAliveDisconnect = make(chan struct{}, 1) // license 页面 SSE 连接断开信号
var mainAliveDisconnect = make(chan struct{}, 1)    // 主页面 SSE 连接断开信号
var mainAliveConnected atomic.Bool                // 主页面 SSE 连接是否活跃
var serverToken string            // 本地服务 API 鉴权 Token
var currentServerPort int         // 当前服务运行端口
var zenLogFile *os.File           // 前端调试日志文件
var zenLogMu sync.Mutex           // 日志写入锁

// logger 统一日志函数：仅 Debug 模式（_internalFlag=="1"）输出，Release 直接 return
func logger(format string, v ...interface{}) {
	if _internalFlag == "1" {
		log.Printf(format, v...)
	}
}

func init() {
	log.SetPrefix("[zen_desktop] ")
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		h := md5.Sum(fmt.Appendf(nil, "%d%d", time.Now().UnixNano(), os.Getpid()))
		serverToken = hex.EncodeToString(h[:])
	} else {
		serverToken = hex.EncodeToString(tokenBytes)
	}
}

// zenLogHandler 接收前端发来的调试日志，写入文件（仅 debug 版本）
func zenLogHandler(w http.ResponseWriter, r *http.Request) {
	if _internalFlag != "1" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	zenLogMu.Lock()
	defer zenLogMu.Unlock()
	if zenLogFile == nil {
		exePath, _ := os.Executable()
		exeDir := filepath.Dir(exePath)
		logPath := filepath.Join(exeDir, "zen_desktop.log")
		zenLogFile, err = os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			log.Printf("[zenLog] 无法创建日志文件 %s: %v", logPath, err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		zenLogFile.WriteString(fmt.Sprintf("=== zen_desktop debug log: %s ===\n", time.Now().Format("2006-01-02 15:04:05")))
		zenLogFile.Sync()
		log.Printf("[zenLog] 日志文件已创建: %s", logPath)
	}
	zenLogFile.WriteString(string(body) + "\n")
	zenLogFile.Sync()
	w.WriteHeader(http.StatusNoContent)
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
			http.Error(w, "禁止访问", http.StatusForbidden)
			return
		}

		h(w, r)
	}
}

func restartHandler(w http.ResponseWriter, r *http.Request) {
	logger("接收到 API 热重启请求...")
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
	logger("接收到 API 关闭请求...")
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
	logger("[LicenseDecision] 请求到来: path=%s, query=%s", r.URL.Path, r.URL.Query())
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
		return
	}

	acceptStr := r.URL.Query().Get("accept")
	logger("[LicenseDecision] accept=%s", acceptStr)
	if acceptStr == "1" {
		// 用户同意
		select {
		case licenseDecisionChan <- 1:
			logger("[LicenseDecision] 已发送 licenseDecisionChan=1")
		default:
		}
		// 调用 helper 保存接受状态
		logger("[LicenseDecision] 调用 helper accept_license...")
		resp, err := callAuthHelper(AuthHelperRequest{
			Action: "accept_license",
		})
		if err != nil {
			logger("[LicenseDecision] accept_license 失败: %v", err)
		} else {
			logger("[LicenseDecision] accept_license 成功: %+v", resp)
		}
		// 重定向到主页面，让同一个浏览器窗口跳转而非关闭再开新窗口
		http.Redirect(w, r, fmt.Sprintf("/?token=%s", serverToken), 302)
		return
	}

	// 用户取消 - 直接退出，不显示任何页面
	select {
	case licenseDecisionChan <- 0:
		logger("[LicenseDecision] 已发送 licenseDecisionChan=0")
	default:
	}
	// 返回空白页面，不显示任何内容
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(`<!DOCTYPE html><html><head></head><body></body></html>`))
	// 注意：cleanupAndExit 由主循环 licenseDecisionChan 分支统一处理，不要重复调用
}

// licenseAcceptedCache 缓存 check_license 的肯定结果：接受状态在进程生命周期内
// 单向递增（无撤销路径），一旦 accepted 直接复用，避免根路由每次请求都走 helper IPC。
var licenseAcceptedCache atomic.Bool

func checkLicenseAccepted() bool {
	if licenseAcceptedCache.Load() {
		return true
	}
	logger("[CheckLicense] 调用 helper check_license...")
	resp, err := callAuthHelper(AuthHelperRequest{
		Action: "check_license",
	})
	if err != nil {
		logger("检查许可证接受状态失败: %v", err)
		logger("[CheckLicense] 失败: %v", err)
		return false
	}
	logger("[CheckLicense] resp.Success=%v, resp.Message=%s", resp.Success, resp.Message)
	accepted := resp.Success && resp.Message == "accepted"
	logger("[CheckLicense] 结果: %v", accepted)
	if accepted {
		licenseAcceptedCache.Store(true)
	}
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
	logger("检测到 I_agree 文件，视同用户已同意许可证协议")
	resp, err := callAuthHelper(AuthHelperRequest{
		Action: "accept_license",
	})
	if err != nil {
		logger("I_agree 文件: accept_license 失败: %v", err)
		return false
	}
	logger("[IAgree] accept_license 结果: %+v", resp)
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

// instanceUrlCachePath 实例 URL（含 token）的用户级缓存路径：~/Library/Caches/zen_desktop/<port>.url。
// exe 同目录的 .zen_url 会随构建（目录重建）被删，缓存副本跨构建存活，供新实例接管时读取
func instanceUrlCachePath(port int) string {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(cacheDir, "zen_desktop", fmt.Sprintf("%d.url", port))
}

// readStaleInstanceToken 读取占用端口旧实例的会话 token。
// 优先读 exe 同目录 .zen_url（校验端口匹配），回退用户缓存目录 <port>.url（跨构建存活）
func readStaleInstanceToken(port int) string {
	if exePath, err := os.Executable(); err == nil {
		if d, err := os.ReadFile(filepath.Join(filepath.Dir(exePath), ".zen_url")); err == nil {
			if u, err := url.Parse(strings.TrimSpace(string(d))); err == nil && u.Port() == fmt.Sprintf("%d", port) {
				if token := u.Query().Get("token"); token != "" {
					return token
				}
			}
		}
	}
	if p := instanceUrlCachePath(port); p != "" {
		if d, err := os.ReadFile(p); err == nil {
			if u, err := url.Parse(strings.TrimSpace(string(d))); err == nil {
				return u.Query().Get("token")
			}
		}
	}
	return ""
}

// tryStopStaleInstance 尝试让占用端口的旧 zen_desktop 实例优雅退出。
// 使用 .zen_url 中的旧实例 token 鉴权调用 /api/stop；
// 只有 zen_desktop 会实现该端点，无关程序占用时请求失败/404，原样返回 false。
func tryStopStaleInstance(port int) bool {
	token := readStaleInstanceToken(port)
	if token == "" {
		return false
	}
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Post(fmt.Sprintf("http://127.0.0.1:%d/api/stop?token=%s", port, url.QueryEscape(token)), "application/json", nil)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return false
	}
	return resp.StatusCode == http.StatusOK && strings.Contains(string(body), `"ok"`)
}

// waitPortAvailable 轮询等待端口释放（旧实例优雅停机需要一点时间）
func waitPortAvailable(port int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if isPortAvailable(port) {
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

// takeoverPort 端口被占时先尝试接管（停掉旧 zen_desktop 实例），失败返回 false
func takeoverPort(port int) bool {
	if !tryStopStaleInstance(port) {
		return false
	}
	if !waitPortAvailable(port, 5*time.Second) {
		return false
	}
	logger("端口 %d 上的旧实例已停止，新实例接管该端口", port)
	return true
}

func findAvailablePort(specifiedPort int) int {
	if specifiedPort > 0 && specifiedPort < 65536 {
		if isPortAvailable(specifiedPort) {
			logger("使用指定的端口: %d", specifiedPort)
			return specifiedPort
		}
		logger("指定的端口 %d 已被占用，尝试停止旧实例...", specifiedPort)
		if takeoverPort(specifiedPort) {
			return specifiedPort
		}
		logger("指定的端口 %d 无法接管，回退到默认端口...", specifiedPort)
	}

	if isPortAvailable(defaultPort) {
		logger("使用默认端口: %d", defaultPort)
		return defaultPort
	}
	logger("默认端口 %d 被占用，尝试停止旧实例...", defaultPort)
	if takeoverPort(defaultPort) {
		return defaultPort
	}
	logger("默认端口 %d 也被占用（非本程序），开始查找可用端口...", defaultPort)

	port := defaultPort + 1
	for port < 65536 {
		if isPortAvailable(port) {
			logger("找到并使用可用端口: %d", port)
			return port
		}
		port++
	}

	log.Fatal("未能找到任何可用的TCP端口 (8888-65535)。")
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

func getSettingsPath() string {
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		path := filepath.Join(exeDir, ".zen_settings.json")
		testFile := filepath.Join(exeDir, ".zen_write_test")
		if err := os.WriteFile(testFile, []byte("test"), 0600); err == nil {
			os.Remove(testFile)
			return path
		}
	}

	cwd, _ := os.Getwd()
	return filepath.Join(cwd, ".zen_settings.json")
}

func serveStaticFile(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// WASM 文件从 embedded pkg 读取
	if strings.HasSuffix(path, ".wasm") {
		data, err := embeddedFiles.ReadFile("pkg/" + filepath.Base(path))
		if err != nil {
			logger("[ERROR] Failed to read embedded wasm: %v", err)
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
			logger("[ERROR] Failed to read embedded js: %v", err)
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
		logger("⚠️ helper integrity 未配置: 以未校验模式启动 (debug/手动编译常见)。" +
			"release 请通过 build.sh / build.bat 注入 expectedHelperSHA256。")
	} else if helperPath, err := findAuthHelperPath(); err == nil {
		if err := verifyHelperIntegrity(helperPath); err != nil {
			log.Fatalf("认证模块完整性校验失败: %v", err)
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
settingsPath := getSettingsPath()
	core.InitDataSource(settingsPath)
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

		mux.HandleFunc("/license-alive", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			// SSE 长连接：license 页面通过 EventSource 连接到此端点
			// 关键修复：定期发送心跳（SSE 注释行 `: heartbeat\n\n`），防止浏览器/OS/
			// 杀软因连接空闲中断 SSE 长连接导致主循环误判"用户关闭协议页"。
			// EventSource 忽略以 `:` 开头的注释行，但 TCP 数据流保持活跃。
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Cache-Control", "no-cache")
			w.Header().Set("Connection", "keep-alive")
			w.WriteHeader(http.StatusOK)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			logger("License SSE alive connection established")
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-r.Context().Done():
					logger("License SSE alive connection lost (license page closed)")
					select {
					case licenseAliveDisconnect <- struct{}{}:
					default:
					}
					return
				case <-ticker.C:
					// 发送心跳保持 TCP 活跃，写失败说明连接已断
					if _, err := w.Write([]byte(": heartbeat\n\n")); err != nil {
						logger("License SSE heartbeat write failed, connection lost")
						select {
						case licenseAliveDisconnect <- struct{}{}:
						default:
						}
						return
					}
					if f, ok := w.(http.Flusher); ok {
						f.Flush()
					}
				}
			}
		}))

		mux.HandleFunc("/alive", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			// SSE 长连接：主页面通过 EventSource 连接到此端点
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Cache-Control", "no-cache")
			w.Header().Set("Connection", "keep-alive")
			w.WriteHeader(http.StatusOK)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			mainAliveConnected.Store(true)
			logger("Main page SSE alive connection established")
			<-r.Context().Done()
			mainAliveConnected.Store(false)
			logger("Main page SSE alive connection lost (browser closed or backgrounded)")
			select {
			case mainAliveDisconnect <- struct{}{}:
			default:
			}
		}))

		mux.HandleFunc("/license", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			file, err := embeddedFiles.ReadFile("license_agreement.html")
			if err != nil {
				http.Error(w, "服务器内部错误", http.StatusInternalServerError)
				logger("[License] Failed to read license_agreement.html: %v", err)
				return
			}
			logger("Serving license page, size=%d bytes", len(file))
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write(file)
		}))

		// License 决策路由（用于阻塞等待场景）
		mux.HandleFunc("/license-decision", corsHandler(handleLicenseDecision))
		mux.HandleFunc("/api/zenlog", corsHandler(zenLogHandler))
		mux.HandleFunc("/api/health", corsHandler(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(200)
		}))

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
						http.Error(w, "服务器内部错误", http.StatusInternalServerError)
						logger("Error reading embedded license_agreement.html: %v", err)
						return
					}
					w.Header().Set("Content-Type", "text/html; charset=utf-8")
					w.Write(file)
					return
				}
				file, err := embeddedFiles.ReadFile(defaultFile)
				if err != nil {
					http.Error(w, "服务器内部错误", http.StatusInternalServerError)
					logger("Error reading embedded zen.html: %v", err)
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
			WriteTimeout:   0, // 不设写超时：SSE /alive 长连接需要永久阻塞
			MaxHeaderBytes: 1 << 20,
			Handler:        mux,
		}

		serverReady := make(chan struct{})

		go func() {
			logger("服务器正在启动...")

			addr := fmt.Sprintf(":%d", port)
			ln, err := net.Listen("tcp", addr)
			if err != nil {
				log.Fatalf("启动服务器失败: %v", err)
				return
			}

			// 端口监听成功，立即释放信号，无需延迟
			close(serverReady)

			logger("✅ 服务器监听成功，地址: %s", addr)

			if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
				log.Fatalf("服务器运行错误: %v", err)
			}
		}()

		// 输出完整 URL 到 stdout 和文件，方便外部程序获取
		// Release 版不输出到 stdout（仅写文件），避免终端可见日志
		if _internalFlag == "1" {
			fmt.Printf("ZEN_DESKTOP_URL=http://127.0.0.1:%d/?token=%s\n", port, serverToken)
		}
		instanceUrl := fmt.Sprintf("http://127.0.0.1:%d/?token=%s", port, serverToken)
		zenUrlPath := filepath.Join(workDir, ".zen_url")
		os.WriteFile(zenUrlPath, []byte(instanceUrl), 0644)
		setHiddenWindows(zenUrlPath)
		// 双写用户级缓存（构建会重建 exe 目录导致 .zen_url 丢失，缓存副本跨构建存活）
		if p := instanceUrlCachePath(port); p != "" {
			os.MkdirAll(filepath.Dir(p), 0755)
			os.WriteFile(p, []byte(instanceUrl), 0644)
		}

		if isFirstRun && *autoOpenBrowser {
			// 等待服务器就绪信号
			select {
			case <-serverReady:
				// OK
			case <-time.After(2 * time.Second):
				logger("警告: 服务器就绪超时")
			}

		// 关键修复：首次运行 + 显示过 license 弹窗时，license 页面 fetch 成功后
		// 会用 window.location.replace 直接把自己导航到主页面（见
		// docs/license_agreement.js 的 .then 路径），所以 server 这里不能再
		// openBrowser，否则会重复打开一个主页面 tab。
		licenseShown := false

			// 检查是否需要显示 license 弹窗
			if !checkLicenseAccepted() {
				// 检查 exe 同目录下是否存在 I_agree 文件，视同用户已同意
				if checkIAgreeFile() && acceptLicenseViaIAgreeFile() {
					logger("I_agree 文件检测完成，跳过协议弹窗")
				} else {
					logger("检测到用户尚未同意许可证协议，显示弹窗...")

				// 打开 license 页面
				licenseUrl := fmt.Sprintf("http://127.0.0.1:%d/license?token=%s", port, serverToken)
				if err := openBrowser(licenseUrl); err == nil {
					logger("已打开 license 弹窗，等待用户决策...")
				}
				logger("浏览器已打开，等待 license 页面 SSE 连接...")

			licenseLoop:
				for {
					select {
					case decision := <-licenseDecisionChan:
						if decision == 0 {
							logger("用户取消 license，程序退出")
							killHelperProcess()
							cleanupAndExit(1)
						}
						logger("用户已同意 license，继续启动...")
						licenseShown = true
						break licenseLoop
					case <-licenseAliveDisconnect:
						// license 页面 SSE 连接断开 = 页面被关闭
						logger("检测到 license 弹窗已关闭（SSE 连接断开），程序退出")
						killHelperProcess()
						cleanupAndExit(1)
					}
				}
			}
			}

		url := fmt.Sprintf("http://127.0.0.1:%d/?token=%s", port, serverToken)

		logger("")
			logger("========================================")
			logger("  禅中看缠桌面版")
			logger("========================================")
			logger("本地访问: http://127.0.0.1:%d/", port)
			logger("========================================")
			logger("")

			// 只有没显示过 license 弹窗时才需要 server 端主动 openBrowser
			// (例如 restart 后直接进主页面；或 autoOpenBrowser=false 时的"提示用户手动打开"模式)
			if !licenseShown {
				if err := openBrowser(url); err == nil {
					logger("已自动打开浏览器")
				}
			} else {
				// 这条日志是 license_agreement.js 自行 replace 到主页面路径的副产物，
				// 仅在调试/排查"license 后是否开了重复 tab"时有意义；release 不输出。
				logger("license 弹窗已自行导航到主页面，跳过 openBrowser 避免重复")
			}
			isFirstRun = false
		}

		var shouldRestart bool
		var shutdownReason string

mainLoop:
	for {
		select {
		case sig := <-quit:
			// Ctrl+C / SIGTERM: 用户主动中断，无需优雅关闭，直接清理退出
			logger("接收到信号: %v, 立即退出", sig)
			killHelperProcess()
			cleanupAndExit(0)
		case <-restartChan:
			shutdownReason = "API /restart"
			shouldRestart = true
			break mainLoop
		case <-stopChan:
			shutdownReason = "API /stop"
			shouldRestart = false
			break mainLoop
		case <-mainAliveDisconnect:
			// 前端 SSE 连接断开，可能是用户关闭了页面，
			// 也可能是浏览器后台节流导致连接临时断开。
			// 等待 10 秒宽限期，如果期间前端重新建立 SSE 连接（浏览器从后台恢复后 EventSource 自动重连），则不退出。
			logger("主页面 SSE 连接断开，等待 10 秒宽限期...")
			deadline := time.After(10 * time.Second)
			ticker := time.NewTicker(500 * time.Millisecond)
			defer ticker.Stop()
			reconnected := false
		waitLoop:
			for {
				select {
				case <-deadline:
					break waitLoop
				case <-ticker.C:
					if mainAliveConnected.Load() {
						reconnected = true
						break waitLoop
					}
				case sig := <-quit:
					// Ctrl+C 在宽限期内到达，立即退出
					logger("接收到信号: %v, 立即退出", sig)
					killHelperProcess()
					cleanupAndExit(0)
				}
			}
			if reconnected {
				logger("主页面已重新连接，继续运行")
			} else {
				logger("主页面 SSE 连接断开已超 10 秒，判定为页面已关闭，程序退出")
				killHelperProcess()
				cleanupAndExit(0)
			}
			}
		}

		logger("接收到指令 (来源: %s). 准备关闭服务器...", shutdownReason)

		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			logger("服务器关闭失败: %v", err)
		} else {
			logger("服务器已优雅关闭。")
		}

		killHelperProcess()

		if shouldRestart {
			logger("正在热重启服务器...")
			continue Loop
		}

		break Loop
	}
	logger("服务器进程已退出。")
}
