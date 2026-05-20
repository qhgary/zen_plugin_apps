// License Agreement 交互逻辑
// 供 Desktop/Mobile/DLL 平台调用

(function() {
    'use strict';

    var agreeBtn = document.getElementById('agree-button');
    var scrollHint = document.getElementById('scroll-hint');
    var cancelBtn = document.getElementById('cancel-button');

    if (!agreeBtn || !cancelBtn) {
        console.error('License agreement buttons not found');
        return;
    }

    // 检测是否为 DLL 模式 - DLL 通过 MessageBox 交互，HTML 按钮应隐藏
    var isDllMode = window.location.search.indexOf('mode=dll') !== -1;
    if (isDllMode) {
        // DLL 模式下隐藏按钮（由 DLL 的 MessageBox 处理交互）
        agreeBtn.style.display = 'none';
        cancelBtn.style.display = 'none';
        if (scrollHint) scrollHint.style.display = 'none';
        // DLL 使用独立的 HTTP 心跳检测关闭，HTML 不需要 ping
        return;
    }

    // Keepalive ping：每 500ms 通知后端浏览器窗口仍在显示中
    var pingTimer = setInterval(function() {
        fetch('/license-ping', { method: 'POST', keepalive: true }).catch(function() {});
    }, 500);

    // onbeforeunload：浏览器即将关闭时立即通知后端（sendBeacon 比 keepalive 更可靠）
    window.addEventListener('beforeunload', function() {
        clearInterval(pingTimer);
        navigator.sendBeacon('/license-ping', '');
    });

    // 滚动检测：必须滚动到底部才能点击同意
    // 改进：同时监听 license-content 和 window/document 的滚动事件
    // 解决 Windows Edge 等浏览器布局差异导致的检测失效问题
    function checkScrollToBottom() {
        var contentEl = document.getElementById('license-content');
        if (!contentEl) return;
        
        // 检查是否已经滚动到底部（或内容本身就不需要滚动）
        var isAtBottom = contentEl.scrollHeight - contentEl.scrollTop - contentEl.clientHeight < 50;
        
        // 额外检查：如果 scrollHeight <= clientHeight（内容不足以滚动），也直接启用
        var contentNotScrollable = contentEl.scrollHeight <= contentEl.clientHeight;
        
        if (isAtBottom || contentNotScrollable) {
            agreeBtn.disabled = false;
            if (scrollHint) scrollHint.style.display = 'none';
        }
    }

    // 监听 license-content 的滚动
    document.getElementById('license-content').addEventListener('scroll', checkScrollToBottom);
    
    // 同时监听 window 滚动（兼容某些浏览器的事件冒泡或不同滚动机制）
    window.addEventListener('scroll', checkScrollToBottom, { passive: true });
    
    // 页面加载完成后也检查一次（处理内容较少的情况）
    window.addEventListener('load', checkScrollToBottom);
    
    // 立即执行一次检查（确保按钮状态正确）
    checkScrollToBottom();

    // Agree button
    agreeBtn.addEventListener('click', function() {
        // Android platform: call native callback
        if (window.Android && window.Android.onLicenseAgreed) {
            window.Android.onLicenseAgreed();
            return;
        }
        // Desktop platform: use replace navigation to avoid keeping license page in history.
        // This improves close-tab behavior later on the main page.
        fetch('/license-decision?accept=1', { method: 'GET' })
        .then(function() {
            // 显示成功状态并关闭窗口
            document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;background:white;color:#27ae60;"><h1>协议已同意</h1><p>正在启动插件，请稍候...</p></div>';
            setTimeout(function() {
                window.open('', '_self');
                window.close();
                // 冗余手段处理严格策略
                setTimeout(function() { window.location.replace('about:blank'); }, 100);
            }, 500);
        })
        .catch(function(e) {
            // 降级使用重定向，确保后端能收到信号
            window.location.replace('/license-decision?accept=1');
        });
    });

    // Cancel button - close backend and this tab immediately.
    cancelBtn.addEventListener('click', function() {
        // Android platform: call native callback.
        if (window.Android && window.Android.onLicenseCancelled) {
            window.Android.onLicenseCancelled();
            return;
        }
        // Desktop platform:
        // 1) notify backend to exit (best effort),
        // 2) try to close current tab using multiple strategies.
        var cancelUrl = '/license-decision?accept=0';
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
        setTimeout(function() {
            window.location.replace('about:blank');
            window.close();
        }, 120);

        // Final backend-exit fallback if close is blocked.
        setTimeout(function() {
            window.location.replace(cancelUrl);
        }, 260);
    });

    // Desktop 桌面应用不需要 beforeunload 确认，可直接关闭
    // 保留此处以便未来需要时启用
    // window.addEventListener('beforeunload', function(e) { ... });

})();