import __wbg_init, {
  calculate_zen,
  init_auth_attestation as _wfn1,
  get_plugin_version,
  build_zigzag_mode,
  set_processing_mode
} from './pkg/tdx_zen.js';
import './zen_error_codes.js'; // _EC, _RC, _mapEc, needsNativeDialog

const ZEN_DEBUG = false;

if (!ZEN_DEBUG) {
  console.log = function () { };
  console.info = function () { };
  console.debug = function () { };
  console.warn = function () { };
  console.error = function () { };
}

let wasmReady = false;
let wasmInitPromise = null;
const AUTH_APP_ID = 'zen_desktop';
const AUTH_PLATFORM = 'desktop';
const AUTH_SESSION_TIMEOUT_MS = 10000;
const AUTH_CACHE_TTL_MS = 10000; // 10秒，与 DLL 端 VERIFY_INTERVAL_SEC 统一
let authState = {
  valid: false,
  token: '',
  expireStr: '',
  features: 0,
  machineCode: null,
  attestation: '',
  nonce: '',
  appId: AUTH_APP_ID,
  platform: AUTH_PLATFORM,
  lastCheckTs: 0
};
let authSessionRequestSeq = 0;
const pendingAuthSessionRequests = new Map();

// 标记是否正在进行 attestation 过期重试（防止无限循环）
let _attestationRetrying = false;

const AnalysisQueue = {
  currentJobId: null,
  isProcessing: false,
  pendingRequest: null,

  // 严格串行：只要有任务在跑，新请求一律排队，避免 WASM 并发
  // 与不同 jobId 相互踩死锁、auth 重复请求、结果乱序到达
  canProcess(jobId) {
    return !this.isProcessing;
  },

  start(jobId) {
    this.currentJobId = jobId;
    this.isProcessing = true;
  },

  complete() {
    this.isProcessing = false;
  },

  setPending(msg) {
    this.pendingRequest = msg;
  },

  getPending() {
    const req = this.pendingRequest;
    this.pendingRequest = null;
    return req;
  }
};

async function initWasm() {
  if (wasmReady) return;
  if (wasmInitPromise) {
    await wasmInitPromise;
    return;
  }

  wasmInitPromise = (async () => {
    try {
      const wasmUrl = './pkg/tdx_zen_bg.wasm';
      const response = await fetch(wasmUrl);
      if (!response.ok) {
        throw new Error(`Failed to fetch WASM: ${response.status} ${response.statusText}`);
      }
      const wasmBuffer = await response.arrayBuffer();
      await __wbg_init(wasmBuffer);
    } catch (e) {
      throw e;
    }
    wasmReady = true;
  })();

  await wasmInitPromise;
}

function updateAuthState(result, machineCode, emitResult, forceEmit, sessionContext) {
  if (!emitResult) return; // 不 emit 时也不更新 authState，避免试探性调用污染状态
  const prevValid = authState.valid;
  const prevExpire = authState.expireStr;
  const prevFeatures = authState.features;
  const attestation = sessionContext && sessionContext.attestation ? sessionContext.attestation : '';
  const nonce = sessionContext && sessionContext.nonce ? sessionContext.nonce : '';
  const appId = sessionContext && sessionContext.appId ? sessionContext.appId : AUTH_APP_ID;
  const platform = sessionContext && sessionContext.platform ? sessionContext.platform : AUTH_PLATFORM;

  if (result && result.valid) {
    const timestamp = Date.now();
    const random = Math.floor(Math.random() * 1000000);
    const token = `ZEN_TOKEN_${timestamp}_${random}`;
    authState = {
      valid: true,
      token,
      expireStr: result.expire_str || '',
      features: result.features || 0,
      machineCode: machineCode || null,
      attestation,
      nonce,
      appId,
      platform,
      lastCheckTs: Date.now()
    };
  } else {
    authState = {
      valid: false,
      token: '',
      expireStr: '',
      features: 0,
      machineCode: machineCode || null,
      attestation,
      nonce,
      appId,
      platform,
      lastCheckTs: Date.now()
    };
  }

  if (emitResult && result) {
    if (forceEmit || result.valid !== prevValid || result.expire_str !== prevExpire || (result.features || 0) !== prevFeatures) {
      const outResult = Object.assign({ machine_code: machineCode || null }, result);
      postMessage({ id: 'auth_result', result: outResult });
    }
  }
}

function requestAuthSessionFromHost() {
  const requestId = `auth-session-${Date.now()}-${++authSessionRequestSeq}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (!pendingAuthSessionRequests.has(requestId)) return;
      pendingAuthSessionRequests.delete(requestId);
      reject(new Error('timeout'));
    }, AUTH_SESSION_TIMEOUT_MS);

    pendingAuthSessionRequests.set(requestId, { resolve, reject, timer });
    postMessage({
      id: 'request_auth_session',
      request_id: requestId,
      app_id: AUTH_APP_ID,
      platform: AUTH_PLATFORM
    });
  });
}

function resolveAuthSessionRequest(msg) {
  const pending = pendingAuthSessionRequests.get(msg.request_id);
  if (!pending) return;

  pendingAuthSessionRequests.delete(msg.request_id);
  clearTimeout(pending.timer);
  if (msg.success === false) {
    pending.reject(new Error(msg.message || 'failed'));
    return;
  }
  pending.resolve(msg);
}

function initAuthFromSession(session, emitResult, forceEmit) {
  if (!session || !session.attestation) {
    const result = {
      valid: false,
      message: 'missing session',
      expire_str: '',
      features: 0,
      is_trial: false,
      days_left: 0,
      error_code: _EC.UNKNOWN,
    };
    updateAuthState(result, session && session.machine_code ? session.machine_code : null, emitResult, forceEmit);
    return result;
  }

  const result = _wfn1(
    session.attestation,
    session.nonce || '',
    session.app_id || AUTH_APP_ID,
    session.platform || AUTH_PLATFORM
  );
  // WASM 返回 Rust 内部 error_code，映射为公共码后发给主线程
  result.error_code = _mapEc(result.error_code);
  updateAuthState(result, session.machine_code || null, emitResult, forceEmit, {
    attestation: session.attestation,
    nonce: session.nonce || '',
    appId: session.app_id || AUTH_APP_ID,
    platform: session.platform || AUTH_PLATFORM
  });
  return result;
}

async function refreshAuthFromServer() {
  if (authState.valid && authState.lastCheckTs > 0 && (Date.now() - authState.lastCheckTs) < AUTH_CACHE_TTL_MS) {
    return authState;
  }
  try {
    const data = await requestAuthSessionFromHost();
    let finalAttestation = data && data.attestation ? data.attestation : '';
    const license = data && data.license ? data.license : '';
    const machineCode = data && data.machine_code ? data.machine_code : '';
    const nonce = data && data.nonce ? data.nonce : '';
    const appId = data && data.app_id ? data.app_id : AUTH_APP_ID;
    const platform = data && data.platform ? data.platform : AUTH_PLATFORM;

    // 先不 emit，等确认是否需要重试后再决定是否发送 auth_result
    const result = initAuthFromSession({
      attestation: finalAttestation,
      machine_code: machineCode || null,
      nonce: nonce,
      app_id: appId,
      platform: platform
    }, false, false);

    // attestation 过期静默重试：WASM 返回 UNKNOWN 且非重试中时，
    // 静默重新获取一次新 attestation，避免显示"未知错误"
    if (!result.valid && result.error_code === _EC.UNKNOWN && !_attestationRetrying) {
      _attestationRetrying = true;
      try {
        const retryData = await requestAuthSessionFromHost();
        const retryAttestation = retryData && retryData.attestation ? retryData.attestation : '';
        const retryResult = initAuthFromSession({
          attestation: retryAttestation,
          machine_code: (retryData && retryData.machine_code) || machineCode || null,
          nonce: (retryData && retryData.nonce) || '',
          app_id: (retryData && retryData.app_id) || AUTH_APP_ID,
          platform: (retryData && retryData.platform) || AUTH_PLATFORM
        }, true, false);
        if (!retryResult.valid && needsNativeDialog(retryResult.error_code)) {
          triggerNativeDialog(retryResult);
        }
        return retryResult;
      } catch {
        // 重试失败，现在 emit 原始失败结果
        updateAuthState(result, machineCode || null, true, false);
        if (!result.valid && needsNativeDialog(result.error_code)) {
          triggerNativeDialog(result);
        }
        return result;
      } finally {
        _attestationRetrying = false;
      }
    }

    // 非 UNKNOWN 错误或无需重试，正常 emit（forceEmit=true 确保前端收到授权状态更新）
    updateAuthState(result, machineCode || null, true, true);
    if (!result.valid && needsNativeDialog(result.error_code)) {
      triggerNativeDialog(result);
    }
    return result;
  } catch (e) {
    const errMsg = (e && e.message) || '';
    let errorCode = _EC.UNKNOWN;
    // 区分网络错误类型：后台服务器退出 vs 网络超时
    if (errMsg.includes('Failed to fetch') || errMsg.includes('Load failed') || errMsg.includes('NetworkError')) {
      errorCode = _EC.BACKEND_DOWN;
    } else if (errMsg.includes('timeout')) {
      errorCode = _EC.NETWORK_ERROR;
    }
    const result = { valid: false, message: errMsg || 'failed', expire_str: '', features: 0, is_trial: false, days_left: 0, error_code: errorCode };
    updateAuthState(result, authState.machineCode, true, false);
    return result;
  }
}

// 公共错误码、映射函数已由 zen_error_codes.js 提供

async function triggerNativeDialog(result) {
  try {
    const headers = { 'Content-Type': 'application/json' };
    if (_serverToken) headers['X-Zen-Token'] = _serverToken;
    await fetch('/api/auth_dialog', {
      method: 'POST',
      mode: 'cors',
      headers: headers,
      body: JSON.stringify({
        message: result.message || 'failed',
        error_code: Number(result.error_code) || 0,
        should_exit: false,
      }),
    });
  } catch (e) {
  }
}

async function handleInitAuth(msg) {
  const {
    attestation,
    nonce,
    app_id,
    platform,
    machine_code
  } = msg;
  try {
    await initWasm();
    // 先不 emit，等确认是否需要重试后再决定是否发送 auth_result
    const result = initAuthFromSession({
      machine_code: machine_code || null,
      attestation,
      nonce,
      app_id: app_id || AUTH_APP_ID,
      platform: platform || AUTH_PLATFORM
    }, false, true);

    // attestation 过期静默重试：WASM 返回 UNKNOWN 且非重试中时，
    // 静默重新获取一次新 attestation，避免显示"未知错误"
    if (!result.valid && result.error_code === _EC.UNKNOWN && !_attestationRetrying) {
      _attestationRetrying = true;
      try {
        const retryData = await requestAuthSessionFromHost();
        const retryAttestation = retryData && retryData.attestation ? retryData.attestation : '';
        const retryResult = initAuthFromSession({
          attestation: retryAttestation,
          machine_code: (retryData && retryData.machine_code) || machine_code || null,
          nonce: (retryData && retryData.nonce) || '',
          app_id: (retryData && retryData.app_id) || AUTH_APP_ID,
          platform: (retryData && retryData.platform) || AUTH_PLATFORM
        }, true, true);
        if (retryResult.valid) {
          const pending = AnalysisQueue.getPending();
          if (pending) {
            setTimeout(() => handleAnalyze(pending), 50);
          }
        } else if (needsNativeDialog(retryResult.error_code)) {
          triggerNativeDialog(retryResult);
        }
        return;
      } catch {
        // 重试失败，现在 emit 原始失败结果
        updateAuthState(result, machine_code || null, true, false);
        if (!result.valid && needsNativeDialog(result.error_code)) {
          triggerNativeDialog(result);
        }
        return;
      } finally {
        _attestationRetrying = false;
      }
    }

    // 非 UNKNOWN 错误或无需重试，正常 emit（forceEmit=true 确保前端收到授权状态更新）
    updateAuthState(result, machine_code || null, true, true);

    if (result.valid) {
      const pending = AnalysisQueue.getPending();
      if (pending) {
        setTimeout(() => handleAnalyze(pending), 50);
      }
    } else if (needsNativeDialog(result.error_code)) {
      triggerNativeDialog(result);
    }
  } catch (e) {
    postMessage({ id: 'auth_error', error: 'failed' });
  }
}

async function handleAnalyze(msg) {
  const { jobId, symbol } = msg;

  if (!AnalysisQueue.canProcess(jobId)) {
    AnalysisQueue.setPending(msg);
    return;
  }

  AnalysisQueue.start(jobId);

  try {
    await initWasm();

    const authResult = await refreshAuthFromServer();
    if (!authResult || !authResult.valid) {
      AnalysisQueue.complete();
      postMessage({ id: 'error', jobId, symbol, error: 'Authorization failed', error_code: (authResult && authResult.error_code) || 0 });
      return;
    }

    const { configValues } = msg;
    const { merge, expand, allowCross, processingMode, gapStroke, newStroke } = configValues || {};

    // 设置处理模式（streaming/batch），默认 streaming
    if (typeof set_processing_mode === 'function') {
      set_processing_mode(processingMode || 'streaming');
    }

    const high = new Float32Array(msg.highBuffer);
    const low = new Float32Array(msg.lowBuffer);
    const open = new Float32Array(msg.openBuffer);
    const close = new Float32Array(msg.closeBuffer);

    const zigzagMode = build_zigzag_mode(
      gapStroke || false,
      newStroke || false,
      merge !== false, // 未传时兜底开启拓展（默认 MODE 9004，与 Android 端一致）
      expand || false,
      allowCross || false
    );

    let result = calculate_zen(high, low, open, close, null, zigzagMode);

    // WASM 内部令牌 15 秒 TTL，JS 层缓存 10 秒刷新，正常不会过期。
    // NTP 同步等极端情况下可能返回 null，强制刷新授权并重试一次。
    if (!result) {
      authState.lastCheckTs = 0; // 强制跳过 JS 缓存
      const refreshedAuth = await refreshAuthFromServer();
      if (refreshedAuth && refreshedAuth.valid) {
        result = calculate_zen(high, low, open, close, null, zigzagMode);
      }
      if (!result) {
        AnalysisQueue.complete();
        postMessage({ id: 'error', jobId, symbol, error: 'Authorization failed', error_code: (refreshedAuth && refreshedAuth.error_code) || _EC.UNKNOWN });
        return;
      }
    }

    // calculate_zen 通过 serde_wasm_bindgen 直接返回对象（无 i64 字段，不会产生 BigInt）
    if (!result || typeof result !== 'object') {
      AnalysisQueue.complete();
      postMessage({ id: 'error', jobId, symbol, error: 'analyze returned empty or invalid result' });
      return;
    }

    const analysis = result;

    const response = {
      ...msg,
      id: 'result',
      analysis: analysis
    };
    delete response.highBuffer;
    delete response.lowBuffer;
    delete response.openBuffer;
    delete response.closeBuffer;

    postMessage(response);
  } catch (e) {
    postMessage({ id: 'error', jobId, symbol, error: e.stack || e.message || String(e) });
  } finally {
    AnalysisQueue.complete();

    const pending = AnalysisQueue.getPending();
    if (pending) {
      handleAnalyze(pending);
    }
  }
}

let _serverToken = '';

addEventListener('message', (e) => {
  const msg = e.data;
  if (!msg || !msg.id) return;

  if (msg.id === 'init') {
    if (msg.token) _serverToken = msg.token;
    initWasm().then(() => postMessage({ id: 'ready' })).catch(e => {
      postMessage({ id: 'error', error: String(e) });
    });
  } else if (msg.id === 'auth_session_response') {
    resolveAuthSessionRequest(msg);
  } else if (msg.id === 'analyze') {
    handleAnalyze(msg);
  } else if (msg.id === 'init_auth') {
    handleInitAuth(msg);
  } else if (msg.id === 'get_version') {
    (async () => {
      try {
        await initWasm();
        if (typeof get_plugin_version === 'function') {
          const version = get_plugin_version();
          postMessage({ id: 'version', version: version });
        } else {
          postMessage({ id: 'version', version: 'unknown', error: 'Function not available' });
        }
      } catch (e) {
        postMessage({ id: 'version', version: 'unknown', error: String(e) });
      }
    })();
  }
});