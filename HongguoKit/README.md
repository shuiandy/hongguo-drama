# HongguoKit

原生 App 共用的 Swift 包，平台 macOS 14、iOS 26、tvOS 26。Mac 和 iOS 已经在用，tvOS 接下来接入。

| 模块 | 内容 |
| --- | --- |
| `HongguoCore` | 网络、签名、设备身份、取源、清晰度与 CDN 候选、解析、解密、持久化。不依赖 UI。 |
| `HongguoPlayback` | 把 `PlayInfo` 变成可播放的 `AVPlayerItem` 加 loader：红果的 `EpisodeResolver`、`StreamingResourceLoader`、`MediaPrefixCache`。loader 由 App 持有到换集或关闭。iOS 的 `BookMallFeed`（首页推荐流，`AppFeed` 只剩它用的行解析）、`LocalCastServer`、`SeriesCredits` 暂时也在这里，接 tvOS 时再定归属。 |
| `AppLogic` | 各 App 共用的纯规则，不碰界面和网络：信息流和连播推进、手势换算、定时关闭、写操作同步、历史与点赞合并、首页曝光去重、每集断点、分页请求等（原 iOS 仓库的 `Logic/`，模块名不变）。 |
| `HongguoModels` | 各 App 共用的模型，不碰界面：`DramaBackend`（协议、真实实现 `LiveBackend`、离线样例 `FixtureBackend`）、`AccountModel`（登录态，收藏点赞预约历史，按记录排队的写操作，会话隔离）、`LibraryModel`（本机和账号切换与失败回滚、云端历史合并、不感兴趣、首页曝光去重、每集断点、3 分钟同步循环）、`LoginModel`（扫码登录循环）、`LaunchArguments`（通用启动参数）。原在 iOS App 里，搬过来时规则不变。 |

播放器、手势、画中画、页面布局留在各 App。

落盘位置统一走 `StorageRoot`：默认 Application Support（Mac、iOS 不用设置），tvOS 启动时调一次 `StorageRoot.configure(base:mirror:)` 指向 Caches，并把设置和最近 40 部剧的进度镜像进 `UserDefaults`。这是位置，不是行为开关。

## 一套逻辑，没有平台开关

三端（Mac、iOS、tvOS）走完全相同的代码路径，包里没有按平台切换的开关，App 启动时也不用设任何东西。

| 环节 | 唯一的做法 |
| --- | --- |
| 取源 | 只有 `AuthenticatedPlaybackSource`：官方 iOS 7.4.3 的配置和 UA，先走普通路径 `multi_video_model/v1/`（`mGetVideoModel`），空回复再走场景路径 `multi_video_model/player/v1/`（sinfonlineb，再 sinfonlinea）。只带持久设备和 `x-tt-dt`，不带网页登录的 Cookie（2026-11-20 起带 Cookie 的播放请求一律空回复）。按服务器过期时间缓存到磁盘。空回复时只续期一次同一台设备再问一次。`SeriesService.playInfo`、预热、预取都只是它的入口。 |
| 分集列表 | 只有官网剧集页的 `vid_list`（`SeriesService.episodes`，播放页和详情页同时请求，先到先用）。App 详情接口 `multi_video_detail` 从 2026-11-20 起对官方 App 以外的客户端全部返回空，官方 7.4.3 RPC 表里的几条详情路由都试过（`DetailShapeLiveTests`）。 |
| 设备身份 | 只有 `PersistentAppDevice`（钥匙串，6 小时续期，带 `x-tt-dt`）。播放、搜索、账号、目录、书城、上新、发现、评论、弹幕都用它，没有随机设备或固定设备。 |
| 目录和榜单 | 只有 App（`CatalogService` 调 `DiscoveryAccess`），不读官网页面。 |
| 搜索 | 只有 App 搜索 `AppSearchService`（翻页用它的游标），没有官网搜索、放宽关键词或上新补搜。`NewReleaseService` 是单独的近 7 天上新列表，不参与搜索。 |
| 评论 | 只有 App 评论接口（`EpisodeSocialService.commentsPage`，`EpisodeCommentService` 和 `load` 都用它）。 |
| 官网 | 剧集页：分集列表、简介、封面、集数、完结/连载、评分、剧评、演员表（`SeriesService.episodes`、`SeriesService.publicDetails`、`EpisodeSocialService.reviews`）。另外保留分享链接解析。 |
| 网络防护 | `URLGuard` 一种行为：Fake-IP 和 ULA 都算代理地址，红果自己的 https 域名先放行、后台用 DoH 复核（复核不是公网就从此拦截），其他域名要等 DoH（2 秒），缓存最长 300 秒。真实的内网、回环、链路本地地址一律拦截。 |

已经删掉、不要再加回来的：安卓配置的播放请求、App 快速通道、App 排队通道和 551 签名、未签名的旧接口、官网 360p 备用通道、官网网页片源、网页和旧接口的分集列表兜底、匿名注册的临时设备、`PlatformBehavior`、播放时去掉 Cookie 的匿名重试和换新设备、官网目录和榜单页、官网搜索和 `HongguoSearch` 的补搜链、播放页网页评论、弹幕的本机随机身份（`danmaku-client.json`）、评论和目录的随机设备、`AppFeed` 的分类列表信息流。

## 进度

1. 已完成：Mac 的核心移进来，`macos/` 用本地路径依赖。
2. 已完成：并入 iOS 的核心和播放内核（基线 iOS 382e2c2），iOS 用子模块指向这里。
3. 已完成：两端只留官方 iOS 那套取源逻辑，删掉所有旧通道、兜底和平台开关；目录、搜索、评论也只走 App。
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
