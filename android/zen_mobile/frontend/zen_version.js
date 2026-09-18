// zen_version.js -- APK UI version loader (Android @JavascriptInterface).
//
// Android WebView refuses synchronous XHR on file://, so a direct read of
// assets/VERSION from JS always falls back to ZEN_VERSION_FALLBACK. The UI
// version is now served by MainActivity.AndroidLicenseInterface.getUiVersion(),
// which returns BuildConfig.VERSION_NAME (with the leading "V" stripped).

(function() {
    var ZEN_VERSION_FALLBACK = '0.0.0';

    function readFromJsInterface() {
        try {
            if (typeof window.Android !== 'undefined'
                && typeof window.Android.getUiVersion === 'function') {
                var v = window.Android.getUiVersion();
                if (v && typeof v === 'string' && v.length > 0) return v;
            }
        } catch (e) {
            return null;
        }
        return null;
    }

    window.ZEN_UI_VERSION = readFromJsInterface() || ZEN_VERSION_FALLBACK;
})();