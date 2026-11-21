# 红果短剧 tvOS 版

Apple TV App（tvOS 26+），只写界面、焦点和遥控器交互。取源、选集、设备身份、同步规则和纯规则全部来自共用包 `../HongguoKit`（`HongguoCore`、`HongguoPlayback`、`AppLogic`），和 Mac、iOS 版是同一份代码，没有平台开关。

## 目录

```
project.yml           XcodeGen 工程描述（.xcodeproj 和 App/Info.plist 是生成物，不入库）
App/Sources/          SwiftUI App：入口和顶部标签、Components/（海报卡、货架、氛围背景、加载状态）、Pages/
App/Resources/        资源（分层图标和 Top Shelf 图由 iOS 图标生成）
UITests/              UI 测试（离线、静音启动，检查标签、路由和遥控器焦点）
scripts/build-sim.sh  编到 Apple TV 模拟器（--run 装上并离线静音启动）
scripts/shoot.sh      按启动参数逐页截图到 docs/screenshots/
```

## 存储

Apple TV 没有持久的本地存储。启动时第一件事是 `StorageRoot.configure(base: Caches, mirror: .standard)`：所有落盘文件进 Caches（系统可能清掉），设置和最近 40 部剧的进度另外镜像进 `UserDefaults`（tvOS 给每个 App 500 KB）。离线样例运行不写镜像。

## 启动参数

和 iOS 版同名：

| 参数 | 作用 |
| --- | --- |
| `-HongguoOfflineFixtures YES` | 用内置示例数据，不发任何网络请求 |
| `-HongguoMuted YES` | 静音播放，不占 Mac 的音频输出 |
| `-HongguoRoute <名称>` | 启动后直接到某个标签：`recommend` `theater` `ranking` `following` `search` `me` |

## 构建和测试

```bash
cd tvos
scripts/build-sim.sh --run
scripts/shoot.sh <udid> <label>
xcodebuild -project HongguoDramaTV.xcodeproj -scheme HongguoDramaTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

签名用付费个人团队的自动签名；和 iOS 版一样，团队 id 不进仓库，编真机时在命令行传 `DEVELOPMENT_TEAM`。
