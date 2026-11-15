# PLC 监控 App（Android / Flutter）

谢工爱搞自动化 · 手机端西门子 PLC 监控与操作工具。真机走 S7 协议（S7-1200/1500/300），也支持 Modbus TCP 与 PLCSIM Advanced。

## 功能

| 模块 | 说明 |
|---|---|
| 设备管理 | 多设备卡片、在线状态、编辑/删除（删除自动断通讯，可撤销） |
| 模板系统 | 内置升降机 / 顶升移载 / 升降机带定位 / 滚筒线，可新建、复制、改名、导入导出 |
| 点位配置 | 按区域（I/Q/M/DB）+ 类型（BOOL/INT/DINT/REAL…）填地址，支持符号表注释与扫描填 IP |
| 监控操作 | 状态区只读实时刷新；输出点动「按下置 1、松开置 0」；BOOL 可写 0/1；数值可写（含范围校验） |
| 授权 | 14 位授权码，编号 + 设备码 + 盐走 native MD5，一码一机（盐与算法在 `android/app/src/main/cpp/license.cpp`） |
| 配置分发 | 配置包 `.plccfg` 可导出/分享/批量导出；另一台手机「用 PLC监控 打开」即可合并或覆盖导入 |
| 在线更新 | 检查 Render 上的 `version.json`，App 内下载 APK 并拉起系统安装器 |

## 技术栈

- Flutter（Dart 3.14）/ Android Gradle Plugin 9.x，ABI：arm64-v8a、armeabi-v7a、x86_64
- S7 协议：`lib/s7_client.dart`（TPKT/COTP/S7comm 自实现，读写 DB/I/Q/M）
- Modbus TCP：`lib/modbus_client.dart`（功能码 01/02/03/05）
- 授权：`lib/license.dart` + FFI 调 `liblicense.so`（自实现 MD5，盐分片 XOR 混淆）
- 平台通道：`plc/license`（设备码、签名）、`plc/fileio`（分享、选文件、外部打开、目录、安装 APK）

## 本地构建

```bash
export ANDROID_HOME=<android-sdk>
export JAVA_HOME=<jdk-17>
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

签名配置放在 `android/key.properties`（**不进仓库**）：

```properties
storeFile=D:/path/to/plc_app_release.jks
storePassword=******
keyAlias=plc_app
keyPassword=******
```

没有该文件时自动回退 debug 签名，clone 下来可直接编译运行；但 debug 签名无法覆盖安装线上版本。

## 发布与在线更新

线上站点：**https://plc-monitor-app.onrender.com**（Render 静态站，免费且不休眠）

```
server/                 ← 静态站源目录
├─ index.html           ← 下载页（读 version.json 渲染）
└─ version.json         ← App 检查更新用的元数据
tool/render_build.sh    ← Render 构建脚本：把 server/ 复制成 dist/，再从 Release 抓 APK 进 dist/releases/
```

APK **不进仓库**（50 MB 二进制会让仓库迅速膨胀），而是作为 GitHub Release 附件存放：
`version.json` 的 `apkSource` 指向 Release，`apk` 是给 App 用的相对路径（走 Render CDN 下载）。
Render 构建时按 `apkSource` 把 APK 抓进 `dist/releases/`，手机始终从 `onrender.com` 下载。

### 一条命令发版

```bash
python tool/release.py --version 1.7.3 --notes "修复xxx" --notes "新增yyy"
```

脚本自动完成：改版本号 → 编译 APK → 传成 Release 附件 → 写 `version.json` → 推送仓库 → Render 自动重建。

### 为什么不用 git push

本机出网走白名单代理，`github.com` 的 CONNECT 被拦（502），只有 `api.github.com` 通。
因此仓库更新统一走 REST API：

```bash
python tool/publish.py --message "说明"     # 逐文件建 blob → tree → commit → 移动 main
python tool/upload_release.py --version 1.7.3 --apk server/releases/plc-monitor-v1.7.3.apk
```

App 端逻辑（`lib/update.dart`）：读取 `version.json` → 比较 `build` → 下载 APK 到外部私有目录 → FileProvider 拉起系统安装器。安装需要用户允许一次「安装未知应用」（Android 8+），首次会跳到系统设置页。

## 授权码

```
tool/gen_license.dart    # 命令行算码工具
```

```bash
dart run tool/gen_license.dart 12345678 8890ADB7     # 参数：编号 + 设备码
```

## 许可

内部使用项目，未做开源授权声明。
