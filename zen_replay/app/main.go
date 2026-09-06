package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
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
	"sync/atomic"
	"syscall"
	"time"
)

// maxBodyBytes 限制 HTTP 请求体大小，防止恶意超大请求耗尽内存
const maxBodyBytes = 1 << 20 // 1MB

// ============================================================================
// 配置
// ============================================================================

var _internalFlag string

// logger 统一日志函数：仅 Debug 模式（_internalFlag=="1"）输出，Release 直接 return
func logger(format string, v ...interface{}) {
	if _internalFlag == "1" {
		log.Printf(format, v...)
	}
}

func init() {
	log.SetPrefix("[zen-replay] ")
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}

var (
	serverToken          string
	currentServerPort    int
	currentMachineID     string
	browserPID           int
	expectedHelperSHA256 string
)

var licenseDecisionChan = make(chan int, 1)
var licenseAliveDisconnect = make(chan struct{}, 1) // license 页面 SSE 连接断开信号

// ============================================================================
// 错误码映射（与 zen_desktop/core/go/api.go 保持一致）
// ============================================================================

// 内部错误码必须与 Rust AuthErrorCode 枚举值（src/auth/error_codes.rs）保持一致。
const (
	authErrNone               uint32 = 0
	authErrInvalidFormat      uint32 = 1
	authErrSignatureInvalid   uint32 = 2
	authErrExpired            uint32 = 3
	authErrDeviceMismatch     uint32 = 4
	authErrTrialExpired       uint32 = 5
	authErrTrialTampered      uint32 = 6
	authErrTimeTampered       uint32 = 7
	authErrNetworkTimeFailed  uint32 = 8
	authErrNetworkUnavailable uint32 = 9
	authErrStorageUnavailable uint32 = 10
	authErrUnknown            uint32 = 11
	authErrLicenseFileMissing uint32 = 12
	authErrLicenseExpired     uint32 = 13
)

const (
	publicErrNone             uint32 = 0
	publicErrInvalid          uint32 = 1
	publicErrExpired          uint32 = 2
	publicErrDeviceMismatch    uint32 = 3
	publicErrTampered          uint32 = 4
	publicErrNetworkTimeFailed uint32 = 5
	publicErrNetworkUnavailable uint32 = 8 // 跳过6/7（前端虚拟码：6=后台已退出, 7=网络错误）
	publicErrStorageUnavailable uint32 = 9
	publicErrUnknown            uint32 = 11 // 与 Rust AuthErrorCode::Unknown 对齐
)

func mapErrorCode(internalCode uint32) uint32 {
	switch internalCode {
	case authErrNone:
		return publicErrNone
	case authErrInvalidFormat, authErrSignatureInvalid:
		return publicErrInvalid
	case authErrExpired, authErrTrialExpired, authErrLicenseFileMissing, authErrLicenseExpired:
		return publicErrExpired
	case authErrDeviceMismatch:
		return publicErrDeviceMismatch
	case authErrTrialTampered, authErrTimeTampered:
		return publicErrTampered
	case authErrNetworkTimeFailed:
		return publicErrNetworkTimeFailed
	case authErrNetworkUnavailable:
		return publicErrNetworkUnavailable
	case authErrStorageUnavailable:
		return publicErrStorageUnavailable
	default:
		return publicErrUnknown
	}
}

// ============================================================================
// Auth Helper 请求/响应类型
// ============================================================================

type AuthHelperRequest struct {
	Action     string `json:"action"`
	Nonce      string `json:"nonce,omitempty"`
	AppID      string `json:"app_id,omitempty"`
	Platform   string `json:"platform,omitempty"`
	LicenseKey string `json:"license_key,omitempty"`
}

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

type AuthHelperResponse struct {
	Success     bool          `json:"success"`
	Message     string        `json:"message"`
	MachineCode string        `json:"machine_code"`
	AuthResult  *AuthResponse `json:"auth_result"`
	Attestation string        `json:"attestation"`
	LicenseKey  string        `json:"license_key,omitempty"`
}

// ============================================================================
// Helper 进程管理
// ============================================================================

func helperBinaryName() string {
	if runtime.GOOS == "windows" {
		return "zen_auth_helper.exe"
	}
	return "zen_auth_helper"
}

var (
	helperProcess        *exec.Cmd
	helperStdin          io.WriteCloser
	helperStdout        *bufio.Reader
	helperTempDir       string
	helperMu            sync.Mutex
	handshakeSharedKeyHex string
)

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
	configDir, err := os.UserConfigDir()
	if err == nil {
		zenDir := filepath.Join(configDir, "zen")
		if mkErr := os.MkdirAll(zenDir, 0700); mkErr != nil {
			return "zen_license.key"
		}
		return filepath.Join(zenDir, "zen_license.key")
	}
	return "zen_license.key"
}

// ====== 缠论配置持久化 ======
// .zen_settings.json 存储缠论按钮状态，与桌面版保持一致

var (
	zenConfigMu   sync.RWMutex
	zenConfigData map[string]interface{}
	zenConfigPath string
)

// getSettingsPath 返回 .zen_settings.json 的路径，逻辑与桌面版一致
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

// loadZenConfig 从文件加载缠论配置到内存
func loadZenConfig(path string) {
	zenConfigPath = path
	data, err := os.ReadFile(path)
	if err != nil {
		return // 首次运行，没有配置文件
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return
	}
	zenConfigMu.Lock()
	if rawCfg, ok := raw["zenConfig"].(map[string]interface{}); ok {
		zenConfigData = rawCfg
	} else {
		zenConfigData = make(map[string]interface{})
	}
	zenConfigMu.Unlock()
}

// saveZenConfig 将缠论配置持久化到文件
func saveZenConfig(cfg map[string]interface{}) {
	zenConfigMu.Lock()
	zenConfigData = cfg
	zenConfigMu.Unlock()

	if zenConfigPath == "" {
		return
	}
	data, _ := json.MarshalIndent(map[string]interface{}{
		"zenConfig": cfg,
	}, "", "  ")
	os.WriteFile(zenConfigPath, data, 0600)
	setHiddenWindows(zenConfigPath)
}

// getZenConfig 返回当前缠论配置
func getZenConfig() map[string]interface{} {
	zenConfigMu.RLock()
	defer zenConfigMu.RUnlock()
	return zenConfigData
}

// handleZenConfig 处理缠论配置的读写（GET 读取，POST 保存）
func handleZenConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "GET" {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"zenConfig": getZenConfig(),
		})
		return
	}

	if r.Method == "POST" {
		var req struct {
			ZenConfig map[string]interface{} `json:"zenConfig"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			json.NewEncoder(w).Encode(map[string]interface{}{"success": false, "error": "invalid request"})
			return
		}
		saveZenConfig(req.ZenConfig)
		json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
		return
	}
}

func extractHelperToTemp() (string, error) {
	if len(embeddedHelper) == 0 {
		return "", fmt.Errorf("认证模块未嵌入")
	}
	tempDir := filepath.Join(os.TempDir(), "zen_auth_replay")
	if err := os.MkdirAll(tempDir, 0700); err != nil {
		return "", fmt.Errorf("创建临时目录失败: %w", err)
	}
	helperPath := filepath.Join(tempDir, helperBinaryName())

	// SHA256 校验：已有 helper 一致则复用，不一致（新版本/被篡改）则覆盖。
	if existing, err := os.ReadFile(helperPath); err == nil {
		existingHash := sha256.Sum256(existing)
		embeddedHash := sha256.Sum256(embeddedHelper)
		if bytes.Equal(existingHash[:], embeddedHash[:]) {
			return helperPath, nil
		}
	}
	// 写入失败时返回错误，避免使用被篡改的旧版本
	if err := os.WriteFile(helperPath, embeddedHelper, 0700); err != nil {
		// 如果写入失败但已有文件存在且校验通过（上面已检查），仍可继续使用
		if _, statErr := os.Stat(helperPath); statErr != nil {
			return "", fmt.Errorf("写入认证模块失败: %w", err)
		}
		// 文件已存在但校验不通过（被篡改），写入又失败，拒绝使用
		return "", fmt.Errorf("认证模块校验失败且无法覆盖: %w", err)
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

func generateHandshakeSharedKey() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		log.Fatalf("生成握手密钥失败: %v", err)
	}
	return key
}

func computeHandshakeHMAC(nonce []byte) []byte {
	key, err := hex.DecodeString(handshakeSharedKeyHex)
	if err != nil || len(key) != 32 {
		log.Fatalf("握手密钥未初始化或格式错误: %v", err)
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(nonce)
	return mac.Sum(nil)
}

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

	// 双向认证握手
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("生成握手 nonce 失败: %w", err)
	}
	hmacSig := computeHandshakeHMAC(nonce)
	handshakeReq := map[string]interface{}{
		"action":   "handshake",
		"nonce":    hex.EncodeToString(nonce),
		"hmac":     hex.EncodeToString(hmacSig),
		"pid":      os.Getpid(),
		"platform": "replay",
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
	ready, err := helperStdout.ReadString('\n')
	if err != nil {
		cmd.Process.Kill()
		return fmt.Errorf("等待认证模块响应失败: %w", err)
	}
	ready = strings.TrimSpace(ready)
	if ready != "READY" {
		cmd.Process.Kill()
		if strings.HasPrefix(ready, "REJECT_KEY_MISSING") {
			return fmt.Errorf("认证模块拒绝启动: 握手密钥未注入")
		}
		return fmt.Errorf("认证模块握手验证失败: %q", ready)
	}
	logger("auth helper 握手验证通过，已就绪")

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
	for attempt := 0; attempt < 2; attempt++ {
		stdin := helperStdin
		stdout := helperStdout
		logger("[Helper] ==> action=%s (attempt=%d)", request.Action, attempt+1)
		if _, err := stdin.Write(payload); err != nil {
			logger("[Helper] stdin write failed: %v, restarting", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入认证模块失败: %w", err)
			}
			continue
		}
		if _, err := stdin.Write([]byte("\n")); err != nil {
			logger("[Helper] stdin newline failed: %v, restarting", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("写入认证模块失败: %w", err)
			}
			continue
		}
		line, err := stdout.ReadString('\n')
		if err != nil {
			logger("[Helper] stdout read failed: %v, restarting", err)
			helperProcess = nil
			helperStdin = nil
			helperStdout = nil
			if startErr := startHelperProcessLocked(); startErr != nil {
				return nil, fmt.Errorf("读取认证模块响应失败: %w", err)
			}
			continue
		}
		logger("[Helper] <== response received")
		var response AuthHelperResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			return nil, fmt.Errorf("认证模块响应解析失败: %w", err)
		}
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
	if helperTempDir != "" {
		os.RemoveAll(helperTempDir)
		helperTempDir = ""
	}
}

// ============================================================================
// Attestation 验证
// ============================================================================

// getHelperPublicKeyHex 返回 helper 签名公钥（ed25519）。
// 这是 PUBLIC key，无需混淆——安全依赖于 Helper 闭源二进制中的私钥
// 和 WASM kernel 中的验证。与 zen_desktop 实现保持一致。
func getHelperPublicKeyHex() string {
	return "647f4289b670e31476fc7134cf6472fd8e08de5d5aa18ed64f115d8fd3e4d63a"
}

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

// ============================================================================
// HTTP API 端点
// ============================================================================

// corsHandler 是 HTTP 中间件，统一处理 CORS 和 serverToken 校验。
// 与 zen_desktop 实现保持一致：
//   - CORS 反射请求的 Origin（服务只监听 loopback，反射最稳健）
//   - token 通过 X-Zen-Token 头或 ?token= 查询参数传递
func corsHandler(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Zen-Token")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
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

// handleAuthStatus 返回授权状态（含已有 license_key 明文，用于前端回显）。
// 安全性：服务只监听 localhost 且有 serverToken 鉴验，其他进程无法窃取。
func handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "方法不允许", http.StatusMethodNotAllowed)
		return
	}
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "status",
		AppID:    "tdx_zen",
		Platform: "replay",
	})
	if err != nil {
		logger("[AuthStatus] helper 调用失败: %v", err)
		// 返回结构化的错误响应而不是 null
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(AuthHelperResponse{
			Success:     false,
			Message:     fmt.Sprintf("授权服务不可用: %v", err),
			MachineCode: currentMachineID,
		})
		return
	}
	// 返回 license_key 给前端回显（服务只监听 localhost 且有 token 鉴验）
	if resp != nil && resp.AuthResult != nil {
		resp.AuthResult.ErrorCode = mapErrorCode(resp.AuthResult.ErrorCode)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(resp)
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
		if err := verifyAttestation(resp.Attestation, sessionNonce, req.AppID, req.Platform); err != nil {
			logger("安全拦截: Auth Helper 签名校验失败 (%v)", err)
			http.Error(w, "安全校验失败", http.StatusForbidden)
			return
		}
	}
	// session 端点不需要返回 license_key（仅用于初始授权检查）
	if resp != nil {
		resp.LicenseKey = ""
		if resp.AuthResult != nil {
			resp.AuthResult.ErrorCode = mapErrorCode(resp.AuthResult.ErrorCode)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
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
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:     "save_license",
		LicenseKey: strings.TrimSpace(req.LicenseKey),
		Platform:   "replay",
	})
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
			resp.AuthResult.ErrorCode = mapErrorCode(resp.AuthResult.ErrorCode)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
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
		select {
		case licenseDecisionChan <- 1:
			logger("[LicenseDecision] 已发送 licenseDecisionChan=1")
		default:
		}
		// 调用 helper 保存接受状态（与通达信插件版共享 Dll 变体）
		logger("[LicenseDecision] 调用 helper accept_license...")
		resp, err := callAuthHelper(AuthHelperRequest{
			Action:   "accept_license",
			Platform: "replay",
		})
		if err != nil {
			logger("[LicenseDecision] accept_license 失败: %v", err)
		} else {
			logger("[LicenseDecision] accept_license 成功: %+v", resp)
		}
		// 重定向到主页面
		// from_license=1 确保根路由不会因为 checkLicenseAccepted 的时序问题再次显示协议页面
		http.Redirect(w, r, fmt.Sprintf("/?from_license=1&token=%s", serverToken), 302)
		return
	}

	// 用户取消
	select {
	case licenseDecisionChan <- 0:
		logger("[LicenseDecision] 已发送 licenseDecisionChan=0")
	default:
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(`<!DOCTYPE html><html><head></head><body></body></html>`))
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
		Action:   "check_license",
		Platform: "replay",
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
// 与 zen_desktop/DLL 版机制一致：用于自动化测试等场景跳过协议弹窗
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
		Action:   "accept_license",
		Platform: "replay",
	})
	if err != nil {
		logger("I_agree 文件: accept_license 失败: %v", err)
		return false
	}
	logger("[IAgree] accept_license 结果: %+v", resp)
	return true
}

func getMachineCodeFromHelper() string {
	resp, err := callAuthHelper(AuthHelperRequest{
		Action:   "status",
		AppID:    "tdx_zen",
		Platform: "replay",
	})
	if err != nil {
		return currentMachineID
	}
	if resp != nil && resp.MachineCode != "" {
		return resp.MachineCode
	}
	return currentMachineID
}

// ============================================================================
// 嵌入文件
// ============================================================================

//go:embed replay.html
//go:embed zen_error_codes.js
//go:embed license_agreement.html
//go:embed license_agreement.js
//go:embed pkg
var embeddedFiles embed.FS

// ============================================================================
// 静态文件服务
// ============================================================================

func serveStaticFile(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if strings.HasSuffix(path, ".wasm") {
		data, err := embeddedFiles.ReadFile("pkg/" + filepath.Base(path))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/wasm")
		w.Write(data)
		return
	}
	if strings.HasSuffix(path, ".js") && strings.Contains(path, "tdx_zen") {
		data, err := embeddedFiles.ReadFile("pkg/" + filepath.Base(path))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/javascript")
		w.Write(data)
		return
	}
	http.FileServer(http.FS(embeddedFiles)).ServeHTTP(w, r)
}

// ============================================================================
// 浏览器
// ============================================================================

func openBrowser(url string) error {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("open", url)
		err := cmd.Start()
		if err != nil {
			logger("无法自动打开浏览器，请手动访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
		}
		return nil
	case "windows":
		cmd := exec.Command("cmd", "/c", "start", url)
		hideWindowSysProcAttr(cmd)
		err := cmd.Start()
		if err != nil {
			logger("无法自动打开浏览器，请手动访问: %s", url)
			return err
		}
		if cmd.Process != nil {
			browserPID = cmd.Process.Pid
		}
		return nil
	case "linux":
		browsers := []string{"xdg-open", "google-chrome", "firefox"}
		var cmd *exec.Cmd
		var err error
		for _, b := range browsers {
			cmd = exec.Command(b, url)
			if err = cmd.Start(); err == nil {
				break
			}
		}
		if err != nil {
			cmd = exec.Command("xdg-open", url)
			err = cmd.Start()
		}
		if err != nil {
			logger("无法自动打开浏览器，请手动访问: %s", url)
			return err
		}
		if cmd != nil && cmd.Process != nil {
			browserPID = cmd.Process.Pid
		}
		return nil
	default:
		logger("不支持的平台，请手动访问: %s", url)
		return fmt.Errorf("unsupported platform")
	}
}

func cleanupAndExit(code int) {
	logger("正在清理资源并退出 (code=%d)...", code)
	// 清理 .zen_url 文件
	if exePath, err := os.Executable(); err == nil {
		zenUrlPath := filepath.Join(filepath.Dir(exePath), ".zen_url")
		os.Remove(zenUrlPath)
	}
	killHelperProcess()
	if browserPID > 0 {
		switch runtime.GOOS {
		case "darwin", "linux":
			exec.Command("kill", "-9", fmt.Sprintf("%d", browserPID)).Run()
		case "windows":
			cmd := exec.Command("taskkill", "/F", "/PID", fmt.Sprintf("%d", browserPID))
			hideWindowSysProcAttr(cmd)
			cmd.Run()
		}
	}
	os.Exit(code)
}

// ============================================================================
// 端口
// ============================================================================

func findAvailablePort(specified int) int {
	if specified > 0 {
		return specified
	}
	port := 8765
	for i := 0; i < 100; i++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			ln.Close()
			return port
		}
		port++
	}
	log.Fatalf("找不到可用端口")
	return 0
}

// ============================================================================
// SSE 长连接检测（检测浏览器关闭）
// 前端建立 EventSource 连接到 /alive，后端阻塞该请求。
// 当浏览器关闭标签页时，TCP 连接断开，r.Context().Done() 触发。
// 不受标签页节流影响——TCP 连接由 OS 维持，不依赖 JS 定时器。
// ============================================================================

var aliveDisconnect = make(chan struct{}, 1) // 主页面 SSE 连接断开信号
var aliveConnected atomic.Bool                // 主页面 SSE 连接是否活跃

// ============================================================================
// Main
// ============================================================================

func main() {
	specifiedPort := flag.Int("port", 0, "服务器端口")
	flag.Parse()

	// 设置工作目录
	exePath, err := os.Executable()
	if err != nil {
		log.Fatalf("Failed to get executable path: %v", err)
	}
	workDir := filepath.Dir(exePath)
	os.Chdir(workDir)

	port := findAvailablePort(*specifiedPort)
	currentServerPort = port

	// 生成随机 token（32 字节 = 256 位，与 zen_desktop 一致）
	tokenBytes := make([]byte, 32)
	rand.Read(tokenBytes)
	serverToken = hex.EncodeToString(tokenBytes)

	// 校验 helper
	if expectedHelperSHA256 == "" {
		logger("⚠️ helper integrity 未配置 (debug 模式)")
	} else if helperPath, err := findAuthHelperPath(); err == nil {
		if err := verifyHelperIntegrity(helperPath); err != nil {
			log.Fatalf("认证模块完整性校验失败: %v", err)
		}
	}

	// 异步获取机器码
	go func() {
		currentMachineID = getMachineCodeFromHelper()
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	// 用于 /api/stop 触发退出
	stopCh := make(chan struct{}, 1)

	// 加载缠论配置（.zen_settings.json）
	loadZenConfig(getSettingsPath())

	mux := http.NewServeMux()
	mux.HandleFunc("/api/auth/status", corsHandler(handleAuthStatus))
	mux.HandleFunc("/api/auth/session", corsHandler(handleAuthSession))
	mux.HandleFunc("/api/auth/license", corsHandler(handleAuthLicense))
	mux.HandleFunc("/api/health", corsHandler(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	mux.HandleFunc("/api/zenconfig", corsHandler(handleZenConfig))
	mux.HandleFunc("/api/stop", corsHandler(func(w http.ResponseWriter, r *http.Request) {
		logger("收到 /api/stop 请求，正在关闭服务器...")
		w.WriteHeader(http.StatusNoContent)
		select {
		case stopCh <- struct{}{}:
		default:
		}
	}))
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
		// SSE 长连接：前端通过 EventSource 连接到此端点。
		// 后端阻塞此请求直到前端断开连接（关闭标签页 / 浏览器）。
		// r.Context().Done() 在 TCP 连接断开时由 Go HTTP server 触发。
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		aliveConnected.Store(true)
		logger("SSE alive connection established")
		<-r.Context().Done()
		aliveConnected.Store(false)
		logger("SSE alive connection lost (browser closed or backgrounded)")
		select {
		case aliveDisconnect <- struct{}{}:
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
	mux.HandleFunc("/license-decision", corsHandler(handleLicenseDecision))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			if origin := r.Header.Get("Origin"); origin != "" {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Vary", "Origin")
			}
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Zen-Token")
			// 检查协议是否已同意（与通达信插件版共用同一个 StorageVariant::Dll 锚点）
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
			data, err := embeddedFiles.ReadFile("replay.html")
			if err != nil {
				http.Error(w, "服务器内部错误", http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write(data)
			return
		}
		serveStaticFile(w, r)
	})

	server := &http.Server{
		Addr:           fmt.Sprintf("127.0.0.1:%d", port),
		ReadTimeout:    30 * time.Second,
		WriteTimeout:   0, // 不设写超时：SSE /alive 长连接需要永久阻塞
		MaxHeaderBytes: 1 << 20,
		Handler: mux,
	}

	serverReady := make(chan struct{})
	go func() {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			log.Fatalf("启动服务器失败: %v", err)
			return
		}
		close(serverReady)
		logger("✅ 服务器监听成功: http://127.0.0.1:%d", port)
		if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatalf("服务器运行错误: %v", err)
		}
	}()

	select {
	case <-serverReady:
	case <-time.After(2 * time.Second):
		logger("警告: 服务器就绪超时")
	}

	// 检查是否需要显示协议弹窗
	licenseShown := false
	if !checkLicenseAccepted() {
		// 检查 exe 同目录下是否存在 I_agree 文件，视同用户已同意（与 zen_desktop/DLL 版一致）
		if checkIAgreeFile() && acceptLicenseViaIAgreeFile() {
			logger("I_agree 文件检测完成，跳过协议弹窗")
		} else {
			logger("检测到用户尚未同意许可证协议，显示弹窗...")
			licenseUrl := fmt.Sprintf("http://127.0.0.1:%d/license?token=%s", port, serverToken)
			openBrowser(licenseUrl)
			logger("浏览器已打开，等待 license 页面 SSE 连接...")

		LicenseLoop:
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
					break LicenseLoop
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

	// 输出完整 URL 到 .zen_url 文件，方便外部程序（如 shot.py）获取 token
	zenUrlPath := filepath.Join(workDir, ".zen_url")
	os.WriteFile(zenUrlPath, []byte(url), 0644)
	setHiddenWindows(zenUrlPath)

	logger("")
	logger("========================================")
	logger("  禅中看缠回测工具")
	logger("========================================")
	logger("本地访问: http://127.0.0.1:%d/", port)
	logger("========================================")
	logger("")

	if !licenseShown {
		openBrowser(url)
	} else {
		logger("license 弹窗已自行导航到主页面，跳过 openBrowser 避免重复")
	}

	// SSE 长连接存活检测：等待前端 EventSource 连接
	// 一旦连接建立，后端阻塞直到连接断开（浏览器关闭标签页）
	logger("等待前端 SSE 连接...")

	for {
		select {
		case sig := <-quit:
			// Ctrl+C / SIGTERM: 用户主动中断，无需优雅关闭，直接清理退出
			logger("接收到信号: %v, 立即退出", sig)
			killHelperProcess()
			cleanupAndExit(0)
		case <-stopCh:
			logger("用户请求关闭，正在退出...")
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			server.Shutdown(ctx)
			cancel()
			cleanupAndExit(0)
	case <-aliveDisconnect:
		// 前端 SSE 连接断开，可能是浏览器关闭，也可能是后台节流导致临时断开。
		// 等待 10 秒宽限期，如果期间前端重新建立 SSE 连接则不退出。
		logger("SSE 连接断开，等待 10 秒宽限期...")
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
				if aliveConnected.Load() {
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
			logger("前端已重新连接，继续运行")
		} else {
			logger("SSE 连接断开已超 10 秒，判定为浏览器已关闭，程序退出")
			cleanupAndExit(0)
		}
		}
	}
}
