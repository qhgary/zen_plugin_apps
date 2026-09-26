// License Agreement 交互逻辑
// 供 Desktop/Replay/DLL 平台调用

(function() {
    'use strict';

    // 协议变更重同意模式：desktop/replay 服务端注入 window.__ZEN_EULA_RENEW=1，
    // Android 端以 URL 参数 renew=1 标识。DLL 场景横幅由服务端直接注入 HTML，不经过此分支。
    var renewByParam = false;
    try {
        renewByParam = new URLSearchParams(window.location.search).get('renew') === '1';
    } catch (e) { /* 老浏览器无 URLSearchParams 时按非变更处理 */ }
    if ((window.__ZEN_EULA_RENEW || renewByParam) && document.body) {
        var renewBanner = document.createElement('div');
        renewBanner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;'
            + 'background:#c0392b;color:#fff;text-align:center;padding:6px 16px;'
            + 'font-size:14px;font-weight:600;box-shadow:0 2px 8px rgba(0,0,0,.3);';
        renewBanner.textContent = '协议内容已变更，请重新阅读并同意后方可继续使用';
        document.body.insertBefore(renewBanner, document.body.firstChild);
        var renewSpacer = document.createElement('div');
        renewSpacer.style.cssText = 'height:36px;flex-shrink:0;';
        document.body.insertBefore(renewSpacer, renewBanner.nextSibling);
    }

    var agreeBtn = document.getElementById('agree-button');
    var scrollHint = document.getElementById('scroll-hint');
    var cancelBtn = document.getElementById('cancel-button');

    if (!agreeBtn || !cancelBtn) {
        console.error('License agreement buttons not found');
        return;
    }

    // 读取主程序下发的 serverToken（用于 /license-decision 鉴权）
    // 端点已被 corsHandler 包装，无 token 会被 403 拒绝 → 决策信号丢失、主页打不开
    // 凭据来源优先级：URL ?token=（.zen_url 等旧链接）> 服务端注入的 window.__ZEN_TOKEN。
    // 注入值使请求不依赖 zen_token_<port> cookie——cookie 能否被携带取决于浏览器的
    // 同源/防跟踪策略（Safari ITP、"阻止所有 Cookie"、IP 主机名下的 SameSite=Strict
    // 处理与 Chromium 不同），一旦不发弹窗内请求就全 403。地址栏依然不出现 token。
    // 刻意不用 sessionStorage 缓存：服务重启后 token 会变，旧 token 会压过本次注入的
    // 新 token，导致弹窗内请求 403。
    var serverToken = (function () {
        var params = new URLSearchParams(window.location.search);
        var fromUrl = params.get('token') || '';
        var t = fromUrl || (typeof window.__ZEN_TOKEN === 'string' ? window.__ZEN_TOKEN : '');
        if (fromUrl) {
            params.delete('token');
            var qs = params.toString();
            try {
                history.replaceState(null, '', window.location.pathname + (qs ? '?' + qs : '') + window.location.hash);
            } catch (e) { /* WebView file:// 等场景 replaceState 不可用 */ }
        }
        return t;
    })();

    function withToken(url) {
        if (!serverToken) return url;
        var sep = url.indexOf('?') === -1 ? '?' : '&';
        return url + sep + 'token=' + encodeURIComponent(serverToken);
    }

    // SSE 长连接：后端通过连接断开感知 license 页面关闭
    // 不受浏览器标签页节流影响——TCP 连接由 OS 维持，不依赖 JS 定时器
    var _aliveES = new EventSource(withToken('/license-alive'));

    // onbeforeunload：浏览器即将关闭时主动关闭 SSE 连接，让后端立即感知
    window.addEventListener('beforeunload', function() {
        _aliveES.close();
    });

    // 滚动检测：必须滚动到底部才能点击同意
    // 改进：同时监听 license-content 和 window/document 的滚动事件
    // 解决 Windows Edge 等浏览器布局差异导致的检测失效问题
    var agreed = false;

    function enableAgree() {
        if (agreed) return;
        agreed = true;
        agreeBtn.disabled = false;
        if (scrollHint) scrollHint.style.display = 'none';
    }

    function checkScrollToBottom() {
        var contentEl = document.getElementById('license-content');
        if (!contentEl) return;

        // 检查是否已经滚动到底部（或内容本身就不需要滚动）
        var isAtBottom = contentEl.scrollHeight - contentEl.scrollTop - contentEl.clientHeight < 50;

        // 额外检查：如果 scrollHeight <= clientHeight（内容不足以滚动），也直接启用
        var contentNotScrollable = contentEl.scrollHeight <= contentEl.clientHeight + 2;

        if (isAtBottom || contentNotScrollable) {
            enableAgree();
        }
    }

    // 监听 license-content 的滚动
    document.getElementById('license-content').addEventListener('scroll', checkScrollToBottom, { passive: true });

    // 同时监听 window 滚动（兼容某些浏览器的事件冒泡或不同滚动机制）
    window.addEventListener('scroll', checkScrollToBottom, { passive: true });

    // 页面加载完成后也检查一次（处理内容较少的情况）
    window.addEventListener('load', checkScrollToBottom);

    // 立即执行一次检查（确保按钮状态正确）
    checkScrollToBottom();

    // 延迟再检查一次（等待字体渲染/布局完成后 scrollHeight 可能变化）
    setTimeout(checkScrollToBottom, 500);

    // 方法2：IntersectionObserver（现代浏览器更可靠的检测方式）
    // 在内容末尾插入哨兵元素，检测它是否进入视口
    var contentEl = document.getElementById('license-content');
    if (contentEl && 'IntersectionObserver' in window) {
        var sentinel = document.createElement('div');
        sentinel.style.height = '1px';
        sentinel.style.width = '100%';
        sentinel.style.marginTop = '4px';
        contentEl.appendChild(sentinel);
        var io = new IntersectionObserver(function(entries) {
            entries.forEach(function(entry) {
                if (entry.isIntersecting) {
                    enableAgree();
                }
            });
        }, {
            root: contentEl,
            threshold: 0,
            rootMargin: '0px 0px 80px 0px'
        });
        io.observe(sentinel);
    }

    // Agree button
    agreeBtn.addEventListener('click', function() {
        // Android platform: call native callback
        if (window.Android && window.Android.onLicenseAgreed) {
            window.Android.onLicenseAgreed();
            return;
        }
        // Desktop/Replay platform: use replace navigation to avoid keeping license page in history.
        // This improves close-tab behavior later on the main page.
        fetch(withToken('/license-decision?accept=1'), { method: 'GET' })
        .then(function() {
            document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;background:white;color:#27ae60;"><h1>协议已同意</h1><p>正在启动插件，请稍候...</p></div>';
            // 一律 replace 到不带 token 的主页面：主页 HTML 由服务端注入
            // window.__ZEN_TOKEN，凭据不依赖 cookie 也不进地址栏。
            // from_license=1 规避 checkLicenseAccepted 落盘时序问题；
            // close/about:blank 会让标签页白屏，用户误以为"点同意进不去"
            //（2026-09 replay 实测）。
            setTimeout(function() {
                window.location.replace('/?from_license=1');
            }, 500);
        })
        .catch(function(e) {
            // 降级使用重定向，确保后端能收到信号
            window.location.replace(withToken('/license-decision?accept=1'));
        });
    });

    // Cancel button - close backend and this tab immediately.
    cancelBtn.addEventListener('click', function() {
        // Android platform: call native callback.
        if (window.Android && window.Android.onLicenseCancelled) {
            window.Android.onLicenseCancelled();
            return;
        }
        // Desktop/Replay platform:
        // 1) notify backend to exit (best effort),
        // 2) try to close current tab using multiple strategies.
        var cancelUrl = withToken('/license-decision?accept=0');
        try {
            if (navigator.sendBeacon) {
                navigator.sendBeacon(cancelUrl);
            } else {
                fetch(cancelUrl, { method: 'POST', keepalive: true }).catch(function() {});
            }
        } catch (e) {
            // Ignore network errors and continue closing flow.
        }

        // Preferred path for script-opened pages.
        window.open('', '_self');
        window.close();

        // Fallback path for stricter browser policies.
        // 导航到 about:blank 会销毁本页 JS 上下文，后续不再安排其他回退动作。
        setTimeout(function() {
            window.location.replace('about:blank');
            window.close();
        }, 120);
    });

    // Desktop 桌面应用不需要 beforeunload 确认，可直接关闭
    // 保留此处以便未来需要时启用
    // window.addEventListener('beforeunload', function(e) { ... });

})();
