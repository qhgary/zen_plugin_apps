# 开源应用构建指南 (SETUP.md)

本指南说明如何在 `applications/` 目录下构建开源应用组件（桌面版、回测工具、Android APK）。

## 1. 核心架构：开源与闭源组件

本项目由开源代码与闭源二进制组件构成：

- **开源代码**: 桌面版（`zen_desktop/`）、回测工具（`zen_replay/`）、Android 客户端（`android/`）的前端界面与后端逻辑，以及第三方开源组件（如 `HQChart`）。
- **闭源组件** (`dist/` 目录下): WASM 分析内核、AAR 库、DLL 插件、授权 Helper 等。这些组件是编译所必需的依赖，不能删除。

---

## 2. 前置环境要求

| 组件 | 要求 | 验证命令 | 用途 |
|:---:|:---:|:---:|:---|
| **Go** | 最新稳定版 | `go version` | 构建桌面版和回测工具 |
| **Java JDK** | 17+ | `java -version` | 构建 Android APK |
| **Android SDK** | 已安装 | — | 构建 Android APK |
| **Android NDK** | 对应版本 | — | 构建 Android APK |
| **Gradle** | 无需全局安装 | — | 项目自带 Gradle Wrapper |

> **注意**: 无需 Rust 工具链。`applications/build.sh` 仅构建开源部分，闭源组件已预置于 `dist/` 目录中。

### Android 签名配置（仅 release APK 需要）

`applications/build.sh` 直接读取 `ZEN_ANDROID_*` 环境变量，**不会自动加载任何 `.env.android` 文件**。构建 release APK 前，请先在你自己的 shell 中导出（或手动 source 你准备的 env 文件）：
```
export ZEN_ANDROID_STORE_FILE=/path/to/keystore.jks
export ZEN_ANDROID_STORE_PASSWORD=xxxx
export ZEN_ANDROID_KEY_ALIAS=xxxx
export ZEN_ANDROID_KEY_PASSWORD=xxxx
```
未设置这些变量时，release APK 构建会被跳过（日志提示 "missing signing configuration"）。debug 构建无需签名配置。

---

## 3. 闭源依赖说明

`dist/` 目录下的闭源组件是编译所必需的依赖，不能删除。构建前请确认以下文件存在，否则构建会报错：

- `dist/wasm32-unknown-unknown/release/pkg/` — WASM 分析内核（`tdx_zen.js` + `tdx_zen_bg.wasm`），随发行包预构建提供
- `dist/common/` — 公共资源（`license_agreement.html`、`license_agreement.js`、`manual.html`、`zen_error_codes.js` 等），随发行包预构建提供
- `dist/<target>/release/` — 对应平台的 `zen_auth_helper(.exe)` 授权辅助进程二进制，随发行包预构建提供
- `dist/aarch64-linux-android/release/` — Android 闭源库 `zen_android_api.aar`（构建 APK 需要）

---

## 4. 构建脚本使用说明

构建脚本位于本目录下（`applications/build.sh` / `applications/build.bat`）。

### 构建模式

| 模式 | 说明 |
|:---:|:---|
| `all` | **默认**。构建桌面版 + 回测工具 + Android APK |
| `desktop` | 仅构建桌面版（zen_desktop） |
| `replay` | 仅构建回测工具（zen_replay） |
| `apk` | 仅构建 Android APK（zen_mobile） |
| `clean` | 清理所有构建产物 |
| `help` | 显示帮助信息 |

### 构建配置

| 配置 | 说明 |
|:---:|:---|
| `release` | **默认**。Release 构建（优化，无日志） |
| `debug` | Debug 构建（含日志输出） |

### Windows (`build.bat`)

```cmd
cd applications
build.bat                    :: 默认：构建全部 (release)
build.bat all                :: 同上
build.bat desktop            :: 仅构建桌面版
build.bat replay             :: 仅构建回测工具
build.bat apk                :: 仅构建 Android APK
build.bat clean              :: 清理构建产物
build.bat all debug          :: debug 模式构建全部
```

### Unix/macOS (`build.sh`)

```bash
cd applications
./build.sh                   # 默认：构建全部 (release)
./build.sh all               # 同上
./build.sh desktop           # 仅构建桌面版
./build.sh replay            # 仅构建回测工具
./build.sh apk               # 仅构建 Android APK
./build.sh clean             # 清理构建产物
./build.sh all debug         # debug 模式构建全部
```

---

## 5. 构建产物输出路径

构建完成后，产物位于 `applications/dist/` 目录下：

| 产物 | 路径 |
|:---|:---|
| macOS 桌面版 | `dist/aarch64-apple-darwin/release/zen_desktop/zen_desktop` |
| macOS 回测工具 | `dist/aarch64-apple-darwin/release/zen_replay/zen_replay` |
| Windows 桌面版 | `dist/x86_64-pc-windows-msvc/release/zen_desktop/zen_desktop.exe` |
| Windows 回测工具 | `dist/x86_64-pc-windows-msvc/release/zen_replay/zen_replay.exe` |
| Android APK | `dist/aarch64-linux-android/release/zen_mobile/zen_mobile_universal.apk` |
| Android AAR | `dist/aarch64-linux-android/release/zen_android_api.aar` |
