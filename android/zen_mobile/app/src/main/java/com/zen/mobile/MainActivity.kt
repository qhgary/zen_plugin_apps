package com.zen.mobile

import android.annotation.SuppressLint
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import zen_android_api.Zen_android_api
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var rootLayout: FrameLayout
    private val tag = "ZenMobile"
    private var machineCode = ""
    private var authRuntimeClient: ZenAuthRuntimeClient? = null
    private val isShuttingDown = AtomicBoolean(false)
    private var currentServerPort: Int = 8888
    private var serverToken: String = ""

    private val PREFS_NAME = "ZenMobilePrefs"
    private val KEY_LICENSE_ACCEPTED = "license_accepted"

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        WindowCompat.setDecorFitsSystemWindows(window, false)

        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }
        
        webView = WebView(this)
        rootLayout.addView(webView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        
        ViewCompat.setOnApplyWindowInsetsListener(rootLayout) { view, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(systemBars.left, systemBars.top, systemBars.right, 0)
            insets
        }

        setupWebViewSettings(webView.settings)
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                Log.d(tag, "Page finished: $url")
                
                val fixJs = """
                    (function() {
                        console.log('ZenMobile: Applying stability and touch patches...');
                        window.HQCHART_MOBILE = true;
                        window.IS_MOBILE = true;
                        
                        var originalError = window.onerror;
                        window.onerror = function(msg, url, line, col, error) {
                            if (url && url.indexOf('StockData.js') >= 0) {
                                console.warn('ZenMobile: Suppressed StockData error:', msg);
                                return true; 
                            }
                            if (originalError) return originalError.apply(this, arguments);
                            return false;
                        };

                        if (window.JSChart && window.JSChart.GetResource) {
                            var res = JSChart.GetResource();
                            res.IsMobile = true;
                            res.IsCanvas = true;
                            res.Click2Hover = false;
                        }
                        
                        var style = document.createElement('style');
                        style.innerHTML = `
                            * { -webkit-tap-highlight-color: rgba(66, 133, 244, 0.4) !important; }
                            canvas { cursor: pointer !important; touch-action: pan-y !important; }
                        `;
                        document.head.appendChild(style);

                        var startX, startY, startTime;
                        function simulateEvent(type, x, y, target) {
                            var evt = new MouseEvent(type, {
                                clientX: x, clientY: y, bubbles: true, cancelable: true, view: window
                            });
                            target.dispatchEvent(evt);
                        }

                        document.addEventListener('touchstart', function(e) {
                            startX = e.touches[0].clientX;
                            startY = e.touches[0].clientY;
                            startTime = Date.now();
                        }, true);

                        document.addEventListener('touchend', function(e) {
                            var endX = e.changedTouches[0].clientX;
                            var endY = e.changedTouches[0].clientY;
                            var duration = Date.now() - startTime;
                            var dist = Math.sqrt(Math.pow(endX - startX, 2) + Math.pow(endY - startY, 2));
                            
                            if (dist < 15 && duration < 300) {
                                var target = document.elementFromPoint(endX, endY);
                                if (target && target.tagName === 'CANVAS') {
                                    if (e.cancelable) e.preventDefault();
                                    simulateEvent('mousedown', endX, endY, target);
                                    setTimeout(function() {
                                        simulateEvent('mouseup', endX, endY, target);
                                        simulateEvent('click', endX, endY, target);
                                    }, 20);
                                    target.focus();
                                }
                            }
                        }, true);

                        window.dispatchEvent(new Event('resize'));
                    })();
                """.trimIndent()
                view?.evaluateJavascript(fixJs, null)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                Log.d("ZenJS", "${consoleMessage?.message()}")
                return true
            }
        }

        setContentView(rootLayout)
        webView.requestFocus()

        // 处理 Back 键：在许可证页面按返回键等同于点击"取消"
        webView.setOnKeyListener { _, keyCode, event ->
            if (keyCode == KeyEvent.KEYCODE_BACK && event.action == MotionEvent.ACTION_UP) {
                val currentUrl = webView.url ?: ""
                if (currentUrl.contains("license_agreement")) {
                    // 在许可证页面，按返回键等同于取消
                    webView.evaluateJavascript("window.Android?.onLicenseCancelled()", null)
                    true
                } else {
                    false
                }
            } else {
                false
            }
        }

        authRuntimeClient = ZenAuthRuntimeClient.create(tag)
        val runtimeClient = authRuntimeClient
        if (runtimeClient == null) {
            showFatalAuthError("授权运行时缺失，请安装完整版本")
            return
        }

        // Get machine code using Android APIs (Go/gomobile can't access Android properties reliably)
        val androidMachineCode = getAndroidMachineCode()
        Log.i(tag, "Android native machine code obtained")
        machineCode = androidMachineCode
        webView.addJavascriptInterface(ZenAuthBridge(runtimeClient), "ZenAuthBridge")
        webView.addJavascriptInterface(AndroidLicenseInterface(), "Android") // Add license interface

        Thread {
            try {
                prepareAssets()
                val assetDir = File(filesDir, "zen_assets")
                Log.i(tag, "Starting Go server")
                val port = Zen_android_api.startServer(assetDir.absolutePath, 8888L, machineCode, false).toInt()
                currentServerPort = if (port > 0) port else 8888
                serverToken = Zen_android_api.getAuthToken()
                if (serverToken.isEmpty()) {
                    serverToken = java.util.UUID.randomUUID().toString().replace("-", "")
                    Zen_android_api.setAuthToken(serverToken)
                }
                Log.i(tag, "Go server started on port: $currentServerPort")
                patchLocalServicePort(assetDir, currentServerPort)

                val licenseAccepted = getLicenseAcceptedState()


                val initialUrl = if (licenseAccepted) {
                    "http://127.0.0.1:$currentServerPort/zen_mobile.html?token=$serverToken"
                } else {
                    "http://127.0.0.1:$currentServerPort/license_agreement.html?token=$serverToken"
                }
                Log.d(tag, "Loading initial URL")
                runOnUiThread { webView.loadUrl(initialUrl) }
            } catch (e: Exception) {
                Log.e(tag, "Initialization failed", e)
            }
        }.start()
    }

    private fun showFatalAuthError(message: String) {
        val html = """
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no" />
                <style>
                    body {
                        margin: 0;
                        padding: 24px;
                        background: #111;
                        color: #f5f5f5;
                        font-family: sans-serif;
                    }
                    .box {
                        margin-top: 20vh;
                        padding: 20px;
                        border: 1px solid #444;
                        border-radius: 12px;
                        background: #1c1c1c;
                    }
                    .title {
                        font-size: 18px;
                        margin-bottom: 12px;
                    }
                    .desc {
                        font-size: 14px;
                        line-height: 1.6;
                        color: #ccc;
                    }
                </style>
            </head>
            <body>
                <div class="box">
                    <div class="title">授权初始化失败</div>
                    <div class="desc">$message</div>
                </div>
            </body>
            </html>
        """.trimIndent()
        webView.loadDataWithBaseURL("file:///android_asset/", html, "text/html", "utf-8", null)
    }

    private fun prepareAssets() {
        val assetDir = File(filesDir, "zen_assets")
        
        // 尝试使用符号链接模式（开发时）
        val useSymlink = trySymlinkAssets(assetDir)
        
        if (!useSymlink) {
            // 回退到复制模式
            prepareAssetsCopy(assetDir)
        }
    }

    // 开发模式：使用符号链接指向 APK 中的 assets
    private fun trySymlinkAssets(assetDir: File): Boolean {
        try {
            // 获取 APK 中的原始 assets 路径
            val apkAssetsPath = applicationInfo.sourceDir.let { apkPath ->
                // APK 中 assets 位于 /assets 目录
                // 我们直接在 app 的 filesDir 创建指向 APK 资产的符号链接
                // 但这在普通应用权限下不可行，改用复制模式
                null
            }

            // 检查是否强制使用复制模式（通过 SharedPreferences 控制）
            val prefs = getSharedPreferences("zen_mobile", MODE_PRIVATE)
            if (prefs.getBoolean("force_copy_mode", false)) {
                Log.d(tag, "Force copy mode enabled")
                return false
            }

            // 尝试创建符号链接到源文件（仅用于开发测试）
            // 注意：在生产环境中，APK 的 assets 是只读的，无法创建符号链接
            // 这里我们保留符号链接的可能性，但默认使用复制模式
            return false
        } catch (e: Exception) {
            Log.e(tag, "Symlink mode failed: ${e.message}")
            return false
        }
    }

    private fun prepareAssetsCopy(assetDir: File) {
        if (!assetDir.exists()) assetDir.mkdirs()

        // 拷贝资源
        copyAssets("", assetDir)
    }

    private fun patchLocalServicePort(assetDir: File, port: Int) {
        val svcFile = File(assetDir, "ZenLocalService.js")
        if (svcFile.exists()) {
            try {
                val content = svcFile.readText()
                val patchedContent = content.replace("localhost:8888", "127.0.0.1:$port")
                if (content != patchedContent) svcFile.writeText(patchedContent)
            } catch (e: Exception) {
                Log.e(tag, "Failed to patch ZenLocalService.js", e)
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebViewSettings(settings: WebSettings) {
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = true
            allowContentAccess = true
            setSupportZoom(false)
            builtInZoomControls = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            useWideViewPort = true
            loadWithOverviewMode = true
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
    }

    private fun copyAssets(path: String, destDir: File) {
        val manager = assets
        val list = manager.list(path)
        if (list.isNullOrEmpty()) {
            // 不再跳过 license 文件，确保它被复制
            // if (path.contains("zen_license")) return

            try {
                manager.open(path).use { input ->
                    val outFile = File(destDir, path)
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {}
        } else {
            for (name in list) copyAssets(if (path.isEmpty()) name else "$path/$name", destDir)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        safeShutdown()
    }

    private fun safeShutdown() {
        if (!isShuttingDown.compareAndSet(false, true)) return
        Thread {
            try { Zen_android_api.stopServer() } catch (_: Exception) {}
            runOnUiThread {
                try {
                    webView.stopLoading()
                    webView.loadUrl("about:blank")
                    webView.destroy()
                } catch (_: Exception) {}
                finishAndRemoveTask()
                rootLayout.postDelayed({ exitProcess(0) }, 300)
            }
        }.start()
    }

    private class ZenAuthBridge(
        private val runtimeClient: ZenAuthRuntimeClient
    ) {
        @JavascriptInterface
        fun getStatus(): String {
            val status = runtimeClient.getStatus()
            Log.i("ZenAuthBridge", "getStatus called")
            return status
        }

        @JavascriptInterface
        fun createSession(nonce: String, appId: String, platform: String): String {
            return runtimeClient.createSession(nonce, "zen_mobile", "android")
        }

        @JavascriptInterface
        fun saveLicense(licenseKey: String): String = runtimeClient.saveLicense(licenseKey)
    }

    private class ZenAuthRuntimeClient(
        private val logTag: String
    ) {
        companion object {
            fun create(logTag: String): ZenAuthRuntimeClient? {
                return try {
                    Log.i(logTag, "Using gomobile static API")
                    ZenAuthRuntimeClient(logTag)
                } catch (e: Exception) {
                    Log.e(logTag, "Failed to init auth runtime: ${e.message}")
                    null
                }
            }
        }

        fun getMachineCode(): String? {
            return try {
                Zen_android_api.getMachineCode().takeIf { it.isNotBlank() }
            } catch (e: Exception) {
                Log.e(logTag, "getMachineCode failed: ${e.message}")
                null
            }
        }

        fun getStatus(): String {
            return try {
                Zen_android_api.getStatus() ?: "{\"success\":false}"
            } catch (e: Exception) {
                Log.e(logTag, "getStatus failed: ${e.message}")
                "{\"success\":false}"
            }
        }

        fun createSession(nonce: String, appId: String, platform: String): String {
            return try {
                Zen_android_api.createSession(nonce, appId, platform) ?: "{\"success\":false}"
            } catch (e: Exception) {
                Log.e(logTag, "createSession failed: ${e.message}")
                "{\"success\":false}"
            }
        }

        fun saveLicense(licenseKey: String): String {
            return try {
                Zen_android_api.saveLicense(licenseKey) ?: "{\"success\":false}"
            } catch (e: Exception) {
                Log.e(logTag, "saveLicense failed: ${e.message}")
                "{\"success\":false}"
            }
        }
    }

    private fun getAndroidMachineCode(): String {
        try {
            @Suppress("DEPRECATION")
            val serial = android.os.Build.SERIAL
            if (!serial.isNullOrEmpty() && serial != "unknown" && serial != "0") {
                return hashMachineCode("serial:$serial")
            }
        } catch (_: Exception) {}

        try {
            val props = readBuildProp()
            val hwParts = mutableListOf<String>()

            val platform = props["ro.board.platform"]
            if (!platform.isNullOrEmpty()) {
                hwParts.add("platform:$platform")
            }
            val hardware = props["ro.hardware"] ?: android.os.Build.HARDWARE
            if (!hardware.isNullOrEmpty()) {
                hwParts.add("hw:$hardware")
            }
            val model = props["ro.product.model"] ?: android.os.Build.MODEL
            if (!model.isNullOrEmpty()) {
                hwParts.add("model:$model")
            }
            val abi = props["ro.product.cpu.abi"]
            if (!abi.isNullOrEmpty()) {
                hwParts.add("abi:$abi")
            }

            if (hwParts.isNotEmpty()) {
                return hashMachineCode(hwParts.joinToString("|"))
            }
        } catch (_: Exception) {}

        try {
            @Suppress("DEPRECATION")
            val model = android.os.Build.MODEL
            @Suppress("DEPRECATION")
            val brand = android.os.Build.BRAND
            return hashMachineCode("model:$model|brand:$brand")
        } catch (_: Exception) {}

        return "android-default"
    }

    private fun readBuildProp(): Map<String, String> {
        val props = mutableMapOf<String, String>()
        try {
            val lines = java.io.File("/system/build.prop").readLines()
            for (line in lines) {
                if (line.startsWith("#") || !line.contains("=")) continue
                val parts = line.split("=", limit = 2)
                if (parts.size == 2) {
                    props[parts[0].trim()] = parts[1].trim()
                }
            }
        } catch (_: Exception) {}
        return props
    }

    private fun hashMachineCode(input: String): String {
        val md = java.security.MessageDigest.getInstance("MD5")
        val digest = md.digest(input.toByteArray())
        val hexHash = digest.joinToString("") { "%02x".format(it) }
        return "zen-${hexHash.substring(0, 8)}-${hexHash.substring(8, 16)}"
    }

    private fun getLicenseAcceptedState(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        val accepted = prefs.getBoolean(KEY_LICENSE_ACCEPTED, false)
        if (!accepted) return false
        
        val ts = prefs.getString("license_accepted_ts", "") ?: ""
        val sig = prefs.getString("license_accepted_sig", "") ?: ""
        if (ts.isEmpty() || sig.isEmpty()) return false
        
        return try {
            Zen_android_api.verifyLicenseAgreement(machineCode, ts, sig)
        } catch (e: Exception) {
            false
        }
    }

    private inner class AndroidLicenseInterface {
        @JavascriptInterface
        fun getLicenseContent(): String {
            return try {
                val licenseFile = File(filesDir, "zen_assets/LICENSE")
                if (licenseFile.exists()) {
                    licenseFile.readText()
                } else {
                    Log.e(tag, "LICENSE file not found in assets.")
                    "Error: License file not found."
                }
            } catch (e: Exception) {
                Log.e(tag, "Failed to read LICENSE file: ${e.message}")
                "Error: Failed to read license content."
            }
        }

        @JavascriptInterface
        fun onLicenseAgreed() {
            Log.d(tag, "License agreed by user.")
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val ts = System.currentTimeMillis().toString()
            val sig = try {
                Zen_android_api.signLicenseAgreement(machineCode, ts)
            } catch (e: Exception) {
                Log.e(tag, "signLicenseAgreement failed, license not accepted: ${e.message}")
                return
            }
            prefs.edit()
                .putBoolean(KEY_LICENSE_ACCEPTED, true)
                .putString("license_accepted_ts", ts)
                .putString("license_accepted_sig", sig)
                .apply()
            // SharedPreferences 已保存，下次启动时会检查并加载主页面
            // 这里直接加载主页面即可
            runOnUiThread {
                val url = "http://127.0.0.1:$currentServerPort/zen_mobile.html?token=$serverToken"
                webView.loadUrl(url)
            }
        }

        @JavascriptInterface
        fun onLicenseCancelled() {
            Log.d(tag, "License cancelled by user. Exiting app.")
            try {
                Zen_android_api.stopServer()
            } catch (e: Exception) {
                Log.e(tag, "Failed to stop server: ${e.message}")
            }
            runOnUiThread {
                finishAndRemoveTask()
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }

        @JavascriptInterface
        fun closeApp() {
            Log.d(tag, "closeApp called. Exiting app.")
            try {
                Zen_android_api.stopServer()
            } catch (e: Exception) {
                Log.e(tag, "Failed to stop server: ${e.message}")
            }
            runOnUiThread {
                finishAndRemoveTask()
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }
}
