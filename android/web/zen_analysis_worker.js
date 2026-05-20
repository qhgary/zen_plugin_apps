const ZEN_DEBUG = @ZEN_DEBUG@;

if (!ZEN_DEBUG) {
  self.console.log = function () { };
  self.console.info = function () { };
  self.console.debug = function () { };
  self.console.warn = function () { };
  self.console.error = function () { }
}

let __wbg_init = null;
let calculate_zen = null;
let _wfn1 = null;
let _wfn2 = null;
let get_plugin_version = null;
let build_zigzag_mode = null;

async function loadWasmGlue() {
  if (__wbg_init) {
    console.log('[WASM] Glue already loaded, skipping');
    return;
  }
  try {
    console.log('[WASM] Dynamic importing ./pkg/tdx_zen.js...');
    const glue = await import('./pkg/tdx_zen.js');
    console.log('[WASM] Import result keys:', Object.keys(glue));
    __wbg_init = glue.default;
    calculate_zen = glue.calculate_zen;
    _wfn1 = glue.init_auth_attestation;
    _wfn2 = glue.wasm_create_session;
    get_plugin_version = glue.get_plugin_version;
    build_zigzag_mode = glue.build_zigzag_mode;
    console.log('[WASM] Glue loaded successfully. __wbg_init type:', typeof __wbg_init);
  } catch (e) {
    console.error('[WASM] Failed to load WASM glue:', e);
    throw e;
  }
}

let wasmReady = false;
let wasmInitPromise = null;
const AUTH_APP_ID = 'zen_mobile';
const AUTH_PLATFORM = 'android';
const AUTH_SESSION_TIMEOUT_MS = 10000;
const AUTH_CACHE_TTL_MS = 300000;
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

  canProcess(jobId) {
    return !(this.isProcessing && this.currentJobId === jobId);
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
      console.log('[WASM] Starting WASM initialization...');
      await loadWasmGlue();
      console.log('[WASM] Glue loaded, fetching WASM binary...');

      const wasmUrl = './pkg/tdx_zen_bg.wasm';
      console.log('[WASM] Fetching from:', wasmUrl);

      let response = null;
      let lastError = null;
      const maxRetries = 5;
      for (let i = 0; i < maxRetries; i++) {
        try {
          response = await fetch(wasmUrl);
          console.log('[WASM] Fetch attempt', i, 'status:', response.status, response.statusText);
          if (response.ok) break;
        } catch (e) {
          console.log('[WASM] Fetch attempt', i, 'error:', e.message);
          lastError = e;
        }
        if (i < maxRetries - 1) {
          await new Promise(resolve => setTimeout(resolve, 500));
        }
      }

      if (!response || !response.ok) {
        console.error('[WASM] Fetch failed. Response:', response, 'lastError:', lastError);
        throw new Error('WASM load failed');
      }
      console.log('[WASM] Fetch successful, buffer size:', response.headers.get('content-length'));
      const wasmBuffer = await response.arrayBuffer();
      console.log('[WASM] Buffer size:', wasmBuffer.byteLength);
      console.log('[WASM] Calling __wbg_init...');
      await __wbg_init(wasmBuffer);
      console.log('[WASM] __wbg_init completed');
    } catch (e) {
      console.error('[WASM] Initialization error:', e);
      throw e;
    }
    wasmReady = true;
  })();

  await wasmInitPromise;
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
    let finalAttestation = data && data.attestation ? data.attestation : '';
    const license = data && data.license ? data.license : '';
    const machineCode = data && data.machine_code ? data.machine_code : '';
    const nonce = data && data.nonce ? data.nonce : '';
    const appId = data && data.app_id ? data.app_id : AUTH_APP_ID;
    const platform = data && data.platform ? data.platform : AUTH_PLATFORM;

    if (!finalAttestation && license) {
      await initWasm();
      try {
        if (typeof _wfn2 === 'function') {
          const resultJson = _wfn2(license, machineCode, nonce, appId, platform);
          if (resultJson) {
            const parsed = JSON.parse(resultJson);
            if (parsed && parsed.attestation) {
              finalAttestation = parsed.attestation;
            }
          }
        }
      } catch (e) {
      }
    }

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
          postMessage({ id: 'error', error: 'WASM-glue not loaded: get_plugin_version unavailable. __wbg_init=' + typeof __wbg_init });
          postMessage({ id: 'version', version: 'unknown', error: 'Function not available' });
        }
      } catch (e) {
        postMessage({ id: 'error', error: 'initWasm failed: ' + String(e) });
        postMessage({ id: 'version', version: 'unknown', error: String(e) });
      }
    })();
  }
});