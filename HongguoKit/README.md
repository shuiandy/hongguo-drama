# HongguoKit

原生 App 共用的 Swift 包，平台 macOS 14、iOS 26、tvOS 26。Mac 和 iOS 已经在用，tvOS 接下来接入。

| 模块 | 内容 |
| --- | --- |
| `HongguoCore` | 网络、签名、设备身份、取源、清晰度与 CDN 候选、解析、解密、持久化。不依赖 UI。 |
| `HongguoPlayback` | 把 `PlayInfo` 变成可播放的 `AVPlayerItem` 加 loader：红果的 `EpisodeResolver`、`StreamingResourceLoader`、`MediaPrefixCache`。loader 由 App 持有到换集或关闭。iOS 的 `AppFeed`、`BookMallFeed`、`LocalCastServer`、`SeriesCredits` 暂时也在这里，接 tvOS 时再定归属。 |

播放器、手势、画中画、页面布局留在各 App。

## 一套逻辑，没有平台开关

三端（Mac、iOS、tvOS）走完全相同的代码路径，包里没有按平台切换的开关，App 启动时也不用设任何东西。

| 环节 | 唯一的做法 |
| --- | --- |
| 取源 | 只有 `AuthenticatedPlaybackSource`：官方 iOS 7.4.3 的配置和 UA，场景路径 `multi_video_model/player/v1/`（sinfonlineb，空回复换 sinfonlinea，再换普通路径 `multi_video_model/v1/`），持久设备加 `x-tt-dt`，登录后带 Cookie，按服务器过期时间缓存到磁盘。空回复时依次续期设备、去掉 Cookie 匿名重试、换新设备。`SeriesService.playInfo`、预热、预取都只是它的入口。 |
| 分集列表 | 只有签名的 App 详情接口（`EpisodeSocialService.episodes`）。 |
| 设备身份 | 只有 `PersistentAppDevice`（钥匙串，6 小时续期，带 `x-tt-dt`）。播放、搜索、账号、目录、书城、发现、评论都用它。 |
| 网络防护 | `URLGuard` 一种行为：Fake-IP 和 ULA 都算代理地址，红果自己的 https 域名先放行、后台用 DoH 复核（复核不是公网就从此拦截），其他域名要等 DoH（2 秒），缓存最长 300 秒。真实的内网、回环、链路本地地址一律拦截。 |

已经删掉、不要再加回来的：安卓配置的播放请求、App 快速通道、App 排队通道和 551 签名、未签名的旧接口、官网 360p 备用通道、官网网页片源、网页和旧接口的分集列表兜底、匿名注册的临时设备、`PlatformBehavior`。

## 进度

1. 已完成：Mac 的核心移进来，`macos/` 用本地路径依赖。
2. 已完成：并入 iOS 的核心和播放内核（基线 iOS 382e2c2），iOS 用子模块指向这里。
3. 已完成：两端只留官方 iOS 那套取源逻辑，删掉所有旧通道、兜底和平台开关。
4. 下一步：加入 tvOS App，先用最小 Apple TV App 验证普通 H.264 剧集。
5. 之后再定：Mac 播放器是否换用 iOS 的 `EpisodeResolver` 和 `StreamingResourceLoader`。

## 测试

```bash
cd HongguoKit
swift test                                   # 离线测试（iOS 和 tvOS 用 xcodebuild -scheme HongguoKit-Package -destination 'generic/platform=iOS' build）
HONGGUO_LIVE=1 swift test --filter SourceLiveTests   # 线上测试：播三集加一次搜索，会真的请求红果接口
HONGGUO_LIVE=1 HONGGUO_PROBE="关键词" swift test --filter EmptySourceProbeLiveTests  # 片源为空时的探针
HONGGUO_PROBE=playback swift test --filter PlaybackProbeTests  # 播放内核的线上探针
```
