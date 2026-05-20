import __wbg_init, {
  calculate_zen,
  init_auth_attestation as _wfn1,
  get_plugin_version,
  build_zigzag_mode
} from './pkg/tdx_zen.js';

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
      error_code: _EC.UNAVAILABLE,
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

    const result = initAuthFromSession({
      attestation: finalAttestation,
      machine_code: machineCode || null,
      nonce: nonce,
      app_id: appId,
      platform: platform
    }, true, false);

    if (!result.valid && needsNativeDialog(_mapEc(result.error_code))) {
      result.error_code = _mapEc(result.error_code);
      triggerNativeDialog(result);
    }
    return result;
  } catch (e) {
    const result = { valid: false, message: 'failed', expire_str: '', features: 0, is_trial: false, days_left: 0, error_code: _EC.UNAVAILABLE };
    updateAuthState(result, authState.machineCode, true, false);
    return result;
  }
}

const _EC = { NONE: 0, INVALID: 1, EXPIRED: 2, DEVICE_MISMATCH: 3, TAMPERED: 4, UNAVAILABLE: 5 };

const _DLG_CODES = new Set([_EC.EXPIRED, _EC.TAMPERED, _EC.UNAVAILABLE]);

function needsNativeDialog(errorCode) {
  return _DLG_CODES.has(Number(errorCode) || 0);
}

function _mapEc(c) {
  const n = Number(c) || 0;
  if (n === 0) return _EC.NONE;
  if (n === 1 || n === 2) return _EC.INVALID;
  if (n === 3 || n === 5 || n === 12 || n === 13) return _EC.EXPIRED;
  if (n === 4) return _EC.DEVICE_MISMATCH;
  if (n === 6 || n === 7) return _EC.TAMPERED;
  return _EC.UNAVAILABLE;
}

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
    } else {
      if (needsNativeDialog(_mapEc(result.error_code))) {
        result.error_code = _mapEc(result.error_code);
        triggerNativeDialog(result);
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