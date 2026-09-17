// zen_version.js -- APK UI version loader (synchronous XHR).
// The page is served by the local Go HTTP server (http://127.0.0.1:<port>/),
// so VERSION must be fetched over HTTP (same origin). file://android_asset is
// kept only as a fallback for harnesses that load the page directly from assets.

(function() {
    var ZEN_TARGET_KEY = 'apk';
    var ZEN_VERSION_FALLBACK = '0.0.0';

    function parseUiVersion(toml, key) {
        var lines = toml.split('\n');
        var inUi = false;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line === '[ui]') { inUi = true; continue; }
            if (inUi && line.charAt(0) === '[') break;
            if (inUi && line.indexOf(key + ' ') === 0) {
                var m = line.match(/=\s*"([^"]+)"/);
                if (m) return m[1];
            }
        }
        return null;
    }

    function loadUiVersion() {
        var sources = ['VERSION', 'file:///android_asset/VERSION'];
        for (var i = 0; i < sources.length; i++) {
            var xhr = new XMLHttpRequest();
            try {
                xhr.open('GET', sources[i], false);
                xhr.send();
            } catch (e) {
                continue;
            }
            if (xhr.status !== 200 && xhr.status !== 0) continue;
            var v = parseUiVersion(xhr.responseText, ZEN_TARGET_KEY);
            if (v) return v;
        }
        return null;
    }

    window.ZEN_UI_VERSION = loadUiVersion() || ZEN_VERSION_FALLBACK;
})();