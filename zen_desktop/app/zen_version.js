// zen_version.js -- Desktop UI version loader (synchronous XHR mirrors umychart.version.js).

(function() {
    var ZEN_TARGET_KEY = 'desktop';
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
        var xhr = new XMLHttpRequest();
        xhr.open('GET', '/VERSION', false);
        try {
            xhr.send();
        } catch (e) {
            return null;
        }
        if (xhr.status !== 200) return null;
        return parseUiVersion(xhr.responseText, ZEN_TARGET_KEY);
    }

    window.ZEN_UI_VERSION = loadUiVersion() || ZEN_VERSION_FALLBACK;
})();