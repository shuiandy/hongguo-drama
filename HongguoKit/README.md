# HongguoKit

原生 App 共用的 Swift 包，平台 macOS 14、iOS 26、tvOS 26。现在只有 macOS 在用；iOS 和 tvOS 会按下面的顺序接进来。

| 模块 | 内容 |
| --- | --- |
| `HongguoCore` | 网络、签名、设备身份、取源、清晰度与 CDN 候选、解析、解密、持久化。不依赖 UI。 |
| `HongguoPlayback` | 把 `PlayInfo` 变成可播放的 `AVPlayerItem` 加 loader：红果的 `EpisodeResolver`、`StreamingResourceLoader`、`MediaPrefixCache`。loader 由 App 持有到换集或关闭。iOS 的 `AppFeed`、`BookMallFeed`、`LocalCastServer`、`SeriesCredits` 暂时也在这里，第 3 步再定归属。 |

播放器、手势、画中画、页面布局留在各 App。

## 平台差异开关

两端故意不同的地方都收在 `PlatformBehavior` 里。各 App 在启动时、第一个请求之前设一次，默认是 Mac：

```swift
PlatformBehavior.current = .iOS   // iOS 和 tvOS App；Mac 不用设
```

| 字段 | `.mac` | `.iOS` |
| --- | --- | --- |
| `clientProfile` | `.android`：播放请求用安卓 7.4.3.32 配置 | `.ios`：所有播放请求（包括排队通道）用官方 iOS 7.4.3 配置和它的 UA |
| `proxyPolicy` | `.strict`：只有 Fake-IP 算代理地址，都要等 DoH（4 秒），缓存 60 秒 | `.mobileProxy`：ULA 也算；红果自己的 https 域名先放行、后台用 DoH 复核（复核不是公网就从此拦截），其他域名照样等 DoH（2 秒），缓存最长 300 秒 |
| `persistentDataDevice` | 否：目录、书城、发现、账号、评论用固定或搜索设备 | 是：用 `PersistentAppDevice`（钥匙串，6 小时续期，带 `x-tt-dt`），登录后带 Cookie |
| `websiteFallbackChannel` | 是：快速 App 源之后试官网备用通道（360p H.264） | 否 |
| `authenticatedSourceFirst` | 是：`SeriesService` 取源、预热、预取都先走 iOS 的 `AuthenticatedPlaybackSource`（iOS 7.4.3 配置、持久设备、模型磁盘缓存），失败再走 Mac 原来的链 | 否：iOS 的 `EpisodeResolver` 自己先走它，`SeriesService` 只做兜底 |

调用方显式传的参数（例如 `playbackRequest(iosProfile:)`）总是优先。

## 迁移顺序

第一阶段只共享代码，Mac 和 iOS 各自保留现在的播放行为和取源顺序。

1. 把 `macos/Sources/HongguoCore` 和它的测试原样移到这里，`macos/` 改为本地路径依赖。Mac 行为不变。
2. 并入 iOS 仓库 `Shims/HongguoCore` 和 `Playback/` 的代码（基线 iOS 382e2c2）。iOS 新增的文件原样加入；两端都有的文件逐项合并，确实冲突的策略做成上面的 `PlatformBehavior` 开关。`PlaybackCache` 直接用 iOS 版（缓存文件名带媒体版本指纹，下载失败换备用 CDN），Mac 升级后旧缓存会重新下载一次。
3. iOS 的子模块指向这里，删掉已经迁走的 shim，用完整 App 构建验收首页、播放、预取和投屏。
4. 加入 tvOS 平台，先用最小 Apple TV App 验证普通 H.264 剧集。
5. 统一取源顺序、Mac 是否换用 iOS 的加载器，用同一组样本比较首帧时间、成功率和清晰度之后再单独决定。

## 测试

```bash
cd HongguoKit
swift test                                   # 离线测试（iOS 和 tvOS 用 xcodebuild -scheme HongguoKit-Package -destination 'generic/platform=iOS' build）
HONGGUO_LIVE=1 swift test --filter SourceTimingLiveTests   # 线上测试，会真的请求红果接口
HONGGUO_PROBE=playback swift test --filter PlaybackProbeTests  # iOS 行为下的线上探针（按 iOS 开关跑）
```
