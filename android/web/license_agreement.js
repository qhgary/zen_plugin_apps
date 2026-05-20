(function() {
    'use strict';

    var agreeBtn = document.getElementById('agree-button');
    var scrollHint = document.getElementById('scroll-hint');
    var cancelBtn = document.getElementById('cancel-button');

    if (!agreeBtn || !cancelBtn) return;

    var isDllMode = window.location.search.indexOf('mode=dll') !== -1;
    if (isDllMode) {
        agreeBtn.style.display = 'none';
        cancelBtn.style.display = 'none';
        if (scrollHint) scrollHint.style.display = 'none';
        return;
    }

    var _token = new URLSearchParams(window.location.search).get('token') || '';
    var _headers = _token ? {'X-Zen-Token': _token} : {};

    var pingTimer = setInterval(function() {
        fetch('/license-ping', { method: 'POST', keepalive: true, headers: _headers }).catch(function() {});
    }, 500);

    window.addEventListener('beforeunload', function() {
        clearInterval(pingTimer);
        navigator.sendBeacon('/license-ping?token=' + encodeURIComponent(_token), '');
    });

    function checkScrollToBottom() {
        var contentEl = document.getElementById('license-content');
        if (!contentEl) return;

        var isAtBottom = contentEl.scrollHeight - contentEl.scrollTop - contentEl.clientHeight < 50;
        var contentNotScrollable = contentEl.scrollHeight <= contentEl.clientHeight;

        if (isAtBottom || contentNotScrollable) {
            agreeBtn.disabled = false;
            if (scrollHint) scrollHint.style.display = 'none';
        }
    }

    document.getElementById('license-content').addEventListener('scroll', checkScrollToBottom);
    window.addEventListener('scroll', checkScrollToBottom, { passive: true });
    window.addEventListener('load', checkScrollToBottom);
    checkScrollToBottom();

    agreeBtn.addEventListener('click', function() {
        if (window.Android && window.Android.onLicenseAgreed) {
            window.Android.onLicenseAgreed();
            return;
        }
        fetch('/license-decision?accept=1', { method: 'GET', headers: _headers })
        .then(function() {
            document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;background:white;color:#27ae60;"><h1>协议已同意</h1><p>正在启动插件，请稍候...</p></div>';
            setTimeout(function() {
                window.open('', '_self');
                window.close();
                setTimeout(function() { window.location.replace('about:blank'); }, 100);
            }, 500);
        })
        .catch(function(e) {
            window.location.replace('/license-decision?accept=1');
        });
    });

    cancelBtn.addEventListener('click', function() {
        if (window.Android && window.Android.onLicenseCancelled) {
            window.Android.onLicenseCancelled();
            return;
        }
        var cancelUrl = '/license-decision?accept=0&token=' + encodeURIComponent(_token);
        try {
            if (navigator.sendBeacon) {
                navigator.sendBeacon(cancelUrl);
            } else {
                fetch(cancelUrl, { method: 'POST', keepalive: true, headers: _headers }).catch(function() {});
            }
        } catch (e) {
        }

        window.open('', '_self');
        window.close();

        setTimeout(function() {
            window.location.replace('about:blank');
            window.close();
        }, 120);

        setTimeout(function() {
            window.location.replace(cancelUrl);
        }, 260);
    });

})();