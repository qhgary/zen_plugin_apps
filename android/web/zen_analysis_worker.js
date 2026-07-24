const ZEN_DEBUG = @ZEN_DEBUG@;

if (!ZEN_DEBUG) {
 self.console.log = function () { };
 self.console.info = function () { };
 self.console.debug = function () { };
 self.console.error = function () { }
}

// 使用静态 ESM import（与 desktop保持一致）。动态 import() 在某些 Android
// WebView 上行为不可靠，会导致 WASM 版本号 (zen-...) 显示不出来。
import __wbg_init, {
 calculate_zen,
 init_auth_attestation as _wfn1,
 get_plugin_version,
 build_zigzag_mode
} from './pkg/tdx_zen.js';

let wasmReady = false;
let wasmInitPromise = null;
const AUTH_APP_ID = 'zen_mobile';
const AUTH_PLATFORM = 'android';
const AUTH_SESSION_TIMEOUT_MS = 10000;
const AUTH_CACHE_TTL_MS = 300000;
const WASM_FETCH_TIMEOUT_MS = 15000;
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

// 带超时的 fetch
function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const signal = controller.signal;
  const timer = setTimeout(() => { controller.abort(); }, timeoutMs);
  const mergedOptions = Object.assign({}, options, { signal });
  return fetch(url, mergedOptions).then(function(response) {
    clearTimeout(timer);
    return response;
  }).catch(function(e) {
    clearTimeout(timer);
    if (e.name === 'AbortError') {
      throw new Error('WASM fetch 超时 (' + timeoutMs + 'ms)');
    }
    throw e;
  });
}

async function initWasm() {
  if (wasmReady) return;
  if (wasmInitPromise) {
    await wasmInitPromise;
    return;
  }

  wasmInitPromise = (async () => {
    try {
      console.log('[WASM] Starting WASM initialization...');
      console.log('[WASM] Glue loaded via static import, fetching WASM binary...');

      const wasmUrl = './pkg/tdx_zen_bg.wasm';
      console.log('[WASM] Fetching from:', wasmUrl);

      let response = null;
      let lastError = null;
      const maxRetries = 3;
      for (let i = 0; i < maxRetries; i++) {
        try {
          response = await fetchWithTimeout(wasmUrl, { cache: "no-store" }, WASM_FETCH_TIMEOUT_MS);
          console.log('[WASM] Fetch attempt', i, 'status:', response.status, response.statusText);
          if (response.ok) break;
        } catch (e) {
          console.log('[WASM] Fetch attempt', i, 'error:', e.message);
          lastError = e;
          response = null;
        }
        if (i < maxRetries - 1) {
          await new Promise(resolve => setTimeout(resolve, 500));
        }
      }

      if (!response || !response.ok) {
        console.error('[WASM] Fetch failed. Response:', response, 'lastError:', lastError);
        throw new Error('WASM load failed: ' + (lastError ? lastError.message : 'no response'));
      }
      console.log('[WASM] Fetch successful, buffer size:', response.headers.get('content-length'));
      const wasmBuffer = await response.arrayBuffer();
      console.log('[WASM] Buffer size:', wasmBuffer.byteLength);
      console.log('[WASM] Calling __wbg_init...');
      await __wbg_init(wasmBuffer);
      console.log('[WASM] __wbg_init completed');
    } catch (e) {
      console.error('[WASM] Initialization error:', e);
      // 清除缓存的 promise，允许后续重试
      wasmInitPromise = null;
      throw e;
    }
    wasmReady = true;
  })();

  try {
    await wasmInitPromise;
  } catch (e) {
    // 如果初始化失败，wasmInitPromise 已在上面被清除
    // 下次调用 initWasm() 时会重新尝试
    throw e;
  }
}

function updateAuthState(result, machineCode, emitResult, forceEmit, sessionContext) {
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
      error_code: 5,
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
    const finalAttestation = data && data.attestation ? data.attestation : '';
    const machineCode = data && data.machine_code ? data.machine_code : '';
    const nonce = data && data.nonce ? data.nonce : '';
    const appId = data && data.app_id ? data.app_id : AUTH_APP_ID;
    const platform = data && data.platform ? data.platform : AUTH_PLATFORM;

    return initAuthFromSession({
      attestation: finalAttestation,
      machine_code: machineCode || null,
      nonce: nonce,
      app_id: appId,
      platform: platform
    }, true, false);
  } catch (e) {
    const result = { valid: false, message: 'failed', expire_str: '', features: 0, is_trial: false, days_left: 0, error_code: 5 };
    updateAuthState(result, authState.machineCode, true, false);
    return result;
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
    const result = initAuthFromSession({
      machine_code: machine_code || null,
      attestation,
      nonce,
      app_id: app_id || AUTH_APP_ID,
      platform: platform || AUTH_PLATFORM
    }, true, true);

    if (result.valid) {
      const pending = AnalysisQueue.getPending();
      if (pending) {
        setTimeout(() => handleAnalyze(pending), 50);
      }
    }
  } catch (e) {
    postMessage({ id: 'auth_error', error: 'failed' });
  }
}

async function handleAnalyze(msg) {
  const { jobId, symbol, mode, period } = msg;
  const analysisMode = (period !== undefined) ? period : mode;

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
      postMessage({ id: 'error', jobId, symbol, error: 'Authorization failed' });
      return;
    }

    const { configValues } = msg;
    const { merge, expand, allowCross, useMergedKPrice } = configValues || {};

    const high = new Float32Array(msg.highBuffer);
    const low = new Float32Array(msg.lowBuffer);
    const open = new Float32Array(msg.openBuffer);
    const close = new Float32Array(msg.closeBuffer);

    const zigzagMode = build_zigzag_mode(
      analysisMode,
      0,
      1,
      useMergedKPrice !== false,
      merge || false,
      expand || false,
      allowCross || false,
      false
    );

    const result = calculate_zen(high, low, open, close, null, zigzagMode);

    if (!result) {
      AnalysisQueue.complete();
      postMessage({ id: 'error', jobId, symbol, error: 'Authorization failed' });
      return;
    }

    if (typeof result !== 'string' || result.length < 2) {
      AnalysisQueue.complete();
      postMessage({ id: 'error', jobId, symbol, error: 'analyze returned empty or invalid result' });
      return;
    }

    const analysis = JSON.parse(result);

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

addEventListener('message', (e) => {
  const msg = e.data;
  if (!msg || !msg.id) return;

  if (msg.id === 'init') {
    initWasm()
      .then(() => {
        postMessage({ id: 'ready' });
        if (msg.getVersion) {
          if (typeof get_plugin_version === 'function') {
            const version = get_plugin_version();
            postMessage({ id: 'version', version: version });
          } else {
            postMessage({ id: 'version', version: 'unknown', error: 'Function not available' });
          }
        }
      })
      .catch(e => {
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
