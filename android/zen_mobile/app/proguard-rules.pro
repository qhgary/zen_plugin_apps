# Keep Go mobile bindings (gomobile generated JNI interface)
-keep class go.** { *; }
-keep class zen_android_api.** { *; }

# Keep JavaScript bridge interfaces (used by WebView addJavascriptInterface)
-keepclassmembers class com.zen.mobile.MainActivity$ZenAuthBridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepclassmembers class com.zen.mobile.MainActivity$AndroidLicenseInterface {
    @android.webkit.JavascriptInterface <methods>;
}

# Keep Android framework classes required by the app
-keep class androidx.** { *; }

# Obfuscate aggressively but preserve method signatures for JNI
-allowaccessmodification
-repackageclasses 'z'

# Remove logging in release builds for security
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
