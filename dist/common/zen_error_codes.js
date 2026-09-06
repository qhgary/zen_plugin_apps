// ============================================================================
// zen_error_codes.js — 公共错误码定义、映射与辅助函数
// ============================================================================
// 被 Replay / Desktop / Android 三个前端共享引用：
//   - HTML 页面通过 <script src="zen_error_codes.js"></script> 引入
//   - ES Module Worker 通过 import './zen_error_codes.js' 引入（side-effect import）
// 引入后所有符号挂载到 self（window / WorkerGlobalScope）上。
//
// 公共错误码（与后端 Go 的 PublicErr* / Rust AuthErrorCode 映射后结果一致）：
//   0=无错误, 1=授权码无效, 2=授权已过期, 3=机器码不匹配, 4=数据异常,
//   5=时间同步失败, 6=后台已退出(前端虚拟码), 7=网络错误(前端虚拟码),
//   8=网络不可用, 9=存储异常, 11=未知错误
// ============================================================================

(function () {
  'use strict';

  // 公共错误码常量（与后端 MapErrorCode / Go PublicErr* 完全一致）
  const _EC = {
    NONE: 0, INVALID: 1, EXPIRED: 2, DEVICE_MISMATCH: 3, TAMPERED: 4,
    NETWORK_TIME_FAILED: 5, BACKEND_DOWN: 6, NETWORK_ERROR: 7,
    NETWORK_UNAVAILABLE: 8, STORAGE_UNAVAILABLE: 9,
    TRIAL_UNSUPPORTED: 10, // Android 特有：不支持试用
    UNKNOWN: 11
  };

  // Rust AuthErrorCode 内部码（与 src/auth/error_codes.rs 枚举值保持一致）
  const _RC = {
    None: 0, InvalidFormat: 1, SignatureInvalid: 2, Expired: 3, DeviceMismatch: 4,
    TrialExpired: 5, TrialTampered: 6, TimeTampered: 7, NetworkTimeFailed: 8,
    NetworkUnavailable: 9, StorageUnavailable: 10, Unknown: 11,
    LicenseFileMissing: 12, LicenseExpired: 13
  };

  // 根据 error_code 返回 badge 显示文本
  function _zenErrorBadgeText(ec) {
    switch (Number(ec) || 0) {
      case _EC.NONE: return '授权通过';
      case _EC.INVALID: return '授权码无效';
      case _EC.EXPIRED: return '授权已过期';
      case _EC.DEVICE_MISMATCH: return '机器码不匹配';
      case _EC.TAMPERED: return '数据异常';
      case _EC.NETWORK_TIME_FAILED: return '时间同步失败';
      case _EC.BACKEND_DOWN: return '后台已退出';
      case _EC.NETWORK_ERROR: return '网络错误';
      case _EC.NETWORK_UNAVAILABLE: return '网络不可用';
      case _EC.STORAGE_UNAVAILABLE: return '存储异常';
      case _EC.TRIAL_UNSUPPORTED: return '不支持试用';
      default: return '未知错误';
    }
  }

  // 判断是否为授权类错误（需要弹授权面板）
  // 只有授权本身有问题时才弹面板：
  //   授权码无效(1)、授权已过期(2)、机器码不匹配(3)、数据异常/篡改(4)、不支持试用(10)
  // 网络问题、NTP 失败、存储异常、后台退出等非授权本身的问题不弹面板，
  // 避免网络抖动等临时故障导致反复弹窗关不掉。
  function _zenIsAuthError(ec) {
    ec = Number(ec) || 0;
    return ec === _EC.INVALID || ec === _EC.EXPIRED ||
           ec === _EC.DEVICE_MISMATCH || ec === _EC.TAMPERED ||
           ec === _EC.TRIAL_UNSUPPORTED;
  }

  // 根据 error_code 返回授权面板中显示的错误消息
  // 与 _zenErrorBadgeText 一致，但未映射的码优先用后端原始消息
  function _zenErrMsg(ec, fallbackMsg) {
    ec = Number(ec) || 0;
    var text = _zenErrorBadgeText(ec);
    // _zenErrorBadgeText 已知码返回对应文本，未知码返回 '未知错误'
    // 对于未映射的码，优先使用后端原始消息
    if (ec === _EC.NONE || (ec > _EC.STORAGE_UNAVAILABLE && ec !== _EC.UNKNOWN) || text === '未知错误') {
      return fallbackMsg || text;
    }
    return text;
  }

  // 原生对话框仅在以下场景需要（均由前端自行处理，不经过 Worker triggerNativeDialog）：
  //   1. 协议展示页面用户未点击同意就关闭 → license_agreement.js 中处理
  //   2. 主界面发现后台被停止/中断（BACKEND_DOWN）→ 前端 _showSSEErrorDialog 处理
  // 其余授权错误（EXPIRED / TAMPERED / NETWORK_TIME_FAILED 等）不需要弹原生对话框，
  // 授权面板的 errMsg 显示已足够。
  // 因此 Worker 的 needsNativeDialog 始终返回 false。
  const _DLG_CODES = new Set();

  function needsNativeDialog(errorCode) {
    return _DLG_CODES.has(Number(errorCode) || 0);
  }

  // _mapEc 将 WASM 返回的 Rust AuthErrorCode 内部码映射为公共码
  // 与后端 core.MapErrorCode / zen_replay mapErrorCode 逻辑完全一致
  function _mapEc(c) {
    const n = Number(c) || 0;
    switch (n) {
      case _RC.None: return _EC.NONE;
      case _RC.InvalidFormat: case _RC.SignatureInvalid: return _EC.INVALID;
      case _RC.Expired: case _RC.TrialExpired: case _RC.LicenseFileMissing: case _RC.LicenseExpired: return _EC.EXPIRED;
      case _RC.DeviceMismatch: return _EC.DEVICE_MISMATCH;
      case _RC.TrialTampered: case _RC.TimeTampered: return _EC.TAMPERED;
      case _RC.NetworkTimeFailed: return _EC.NETWORK_TIME_FAILED;
      case _RC.NetworkUnavailable: return _EC.NETWORK_UNAVAILABLE;
      case _RC.StorageUnavailable: return _EC.STORAGE_UNAVAILABLE;
      default: return _EC.UNKNOWN;
    }
  }

  // 挂载到全局（window / WorkerGlobalScope）
  // HTML <script src> 模式和 Worker import 模式都能访问
  self._EC = _EC;
  self._RC = _RC;
  self._zenErrorBadgeText = _zenErrorBadgeText;
  self._zenIsAuthError = _zenIsAuthError;
  self._zenErrMsg = _zenErrMsg;
  self._DLG_CODES = _DLG_CODES;
  self.needsNativeDialog = needsNativeDialog;
  self._mapEc = _mapEc;
})();
