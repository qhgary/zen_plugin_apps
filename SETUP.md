# 项目构建指南 (SETUP.md)

本指南旨在帮助您快速配置开发环境，理解项目组件构成，并成功完成构建。

## 1. 核心架构：开源与闭源组件

本项目主要由开源代码与必要的闭源二进制组件构成：

- **开源代码**: 当前项目中所有可见的源代码均为开源的，包括 Android 客户端、前端界面逻辑以及相关的第三方开源组件（如 `HQChart`）。
- **闭源组件 (`/dist` 目录下)**: 项目包含以下闭源二进制组件，用于不同平台下的缠论分析逻辑及功能授权：
  - **AAR**: 供 Android 平台使用。
  - **WASM**: 供桌面端和 Android 端使用。
  - **DLL**: 供 Windows 平台下的通达信软件调用。
  - **Helper**: 负责应用的功能授权控制。
- **关系**: 开源构建脚本会在编译过程中链接这些闭源二进制依赖，确保最终生成完整的应用。

---

## 2. 前置环境要求与验证

在执行根目录下的构建脚本 (`build.sh` / `build.bat`) 之前，请确保系统满足以下条件。您可以通过命令行进行验证：

1.  **开发工具**:
    - **Java JDK 17+**: 运行 `java -version` 验证，版本需 >= 17。
    - **Go**: 运行 `go version` 验证，建议安装最新稳定版。
2.  **Android SDK & NDK**: 
    - 必须安装 Android SDK。
    - 必须安装对应版本的 NDK（请在 Android Studio 的 SDK 管理器中检查安装）。
3.  **闭源二进制依赖 (`/dist` 目录下)**:
    构建脚本会检查以下目录下的预编译二进制文件，如果缺失，构建将会报错：
    - `dist\wasm32-unknown-unknown\<profile>\pkg\` (WASM)
    - `dist\common\` (包含 `license_agreement.html`, `license_agreement.js`, `manual.html`)
    - `dist\<target>\<profile>\` (包含对应的 `zen_auth_helper` 二进制)
4.  **Gradle**: 项目使用 Gradle Wrapper (`gradlew`)，无需全局安装。

---

## 5. 构建脚本使用说明

构建脚本位于**项目根目录**。请先进入项目根目录，并确保以上环境已配置完毕。

### Windows (`build.bat`)
在项目根目录下直接执行（默认构建所有内容）：
```cmd
build.bat
```
也可以指定构建特定目标：
```cmd
build.bat apk     # 仅构建安卓端
build.bat desktop # 仅构建桌面端
```

### Unix/macOS (`build.sh`)
在项目根目录下直接执行：
```bash
./build.sh
```
或指定目标：
```bash
./build.sh apk
./build.sh desktop
```
