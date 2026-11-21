# 开发指南

## 环境

Flutter `3.47.9`、Dart `3.12+`、Go `1.24.1+`、Python `3.10+`、JDK 17、Android SDK 36、NDK `28.2.13676358`。

构建脚本默认设置 `GOPROXY=https://goproxy.cn,direct`、`GOSUMDB=off`，同名环境变量可覆盖。

## 调试运行

Flutter 运行前必须先编译对应架构的 Go 核心：

~~~sh
python3 scripts/build_native.py --platform android --abi arm64-v8a
flutter pub get --enforce-lockfile
flutter run
~~~

本仓库不含站源代码。站源是运行时加载的 JS 模块，调试时把模块文件夹放进数据目录的 `modules` 下；仓库里的 `native/module_example/jsexample` 是只返回假数据的示例模块，用来调试界面。

## 出包

~~~sh
python3 scripts/build_android.py               # 32 位 + 64 位整合包
python3 scripts/build_android.py --abi arm64-v8a
~~~

产物在 `dist/android`。本机签名读 `android/key.properties`（不入库）。

其他脚本：`generate_brand_assets.py` 从 `brand_icon.svg` 生成图标与电视横幅；`clear_app_data.py`、`clear_catalog_cache.py` 清理应用数据和剧库缓存。

## 检查与测试

~~~sh
flutter analyze
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
cd native && go test -race ./...
~~~

Flutter 测试一律带 `DISABLE_REMOTE_IMAGES=true` 避免加载站源图片。测试只覆盖数据兼容、权限和逻辑层，界面改动不写测试。

## 架构

Flutter 界面 + Go 原生核心。站源请求、解析、签名、缓存、下载调度和播放代理都在 Go 里完成，Dart 只负责界面、播放器和本地用户数据。

- **FFI**：`native/bridge` 以 `-buildmode=c-shared` 导出 `DuanjuRequest(json) -> json` 与 `DuanjuFree`，产物 `libduanju_core.so` 放 `android/app/src/main/jniLibs`。`lib/core_bridge.dart` 把每次调用编码成 `{"action": ...}`，Go 侧在 `native/core/app_runtime.go` 的 `NativeRequest` 里按 action 分派。新增能力两端都要改。
- **Go 核心**：`native/core` 是运行时。站源模块由 `module_loader.go` 读取清单并注册，`module_script.go` 用 [goja](https://github.com/dop251/goja) 执行并适配成内部的 `Provider` 接口。`app_*.go` 运行时与业务（目录缓存、下载、弹幕、存储、设置），`network_*.go` HTTP 客户端、DNS、CDN、限流。`app_stream.go` 在本机起播放代理，重写 HLS playlist、透传 Range，并处理带密钥的媒体。
- **Flutter**：界面在 `lib/ui/`（按页面分子目录，入口 `lib/main.dart` → `lib/ui/app.dart`），逻辑层平铺在 `lib/`，状态管理只用 ChangeNotifier。
- **播放**：Android 用 ExoPlayer（media3）原生内核，双播放器结构：主播放 + 备用预热，切集时备用无缝接管；播放地址是 Go 本地流服务器的 `127.0.0.1` 地址，上游请求统一走代理 / DNS 设置。
- **本地数据**：存储格式须兼容旧版。本地快照遇到未知键会整体报错，新增设置若要兼容旧版须存为快照外的独立键。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `lib/ui` | 界面：主题、导航壳、各页面、播放器、公共组件 |
| `lib` | 逻辑层：FFI、站源目录、播放、下载、本地存储与用户 |
| `native/core`、`native/bridge` | Go 运行时（缓存、下载、播放代理）及 C ABI |
| `native/module_example` | 示例站源模块（假数据，不访问网络） |
| `android` | Android 工程与资源 |
| `scripts` | 构建、图标生成与数据清理脚本 |
| `test` | 逻辑层测试 |

## 站源模块

站源是运行时加载的 JS 模块，模块接口为第 1 版（清单里的 `api` 填 `1`）。

- 位置：数据目录下的 `modules/<模块标识>/`，应用启动时加载。
- 文件：`manifest.json` 与 `main.js`，写法参照 `native/module_example/jsexample`。
- 安装包：zip，`manifest.json` 和 `main.js` 放在根目录或唯一的一层文件夹里，整包不超过 8 MB。同一标识覆盖旧版本，安装和卸载不用重启。
- 清单：`id`（小写字母、数字、`_`、`-`，最长 32 字符，须与文件夹同名）、`name`、`version`、`description`、`runtime`（只支持 `js`）、`api`（当前为 `1`）、`adult`（是否限制级内容）、`hosts`（允许请求的域名）、`capabilities`（可选能力）、`rankings`（榜单列表）。
- 入口：`main.js` 是 CommonJS，导出 `categories(force)`、`catalogPage(page, category)`、`detail(sourceId)`、`resolveMedia(task)`，可选 `search`、`suggestions`、`danmaku`、`recommendations` 等（声明对应 `capabilities` 后才会调用）。
- 宿主：全局对象 `host` 提供 `fetch(request)`、`fetchText(request)`、`reserve({ url, lane, background })`、`sleep(ms)`、`log(message)` 等网络与工具接口，以及 `parseUrl`、`parseHtml`、`base64Encode`、`aesCbcDecrypt`、`md5`、`sha256` 等解析与加密能力。请求只能发往清单声明的域名。
- 并发：同一个模块会有多个互不共享变量的实例同时执行，跨调用的数据放进 `loadState` / `saveState` 或 `cacheGet` / `cacheSet`；读改写用 `host.exclusive` 包起来（不可重入）。
- 运行环境不是浏览器也不是 Node：没有 `fetch`、`URL`、`Buffer`、`TextEncoder` 这些全局对象。
- 剧和分集的 ID 会写进用户的追剧、记录和下载，发布后不能改格式。
- 调试：在 `native` 下执行 `go run ./cmd/moduletool <模块目录> <请求 JSON>`。
