# HongguoKit

原生 App 共用的 Swift 包，平台 macOS 14、iOS 26、tvOS 26。Mac 和 iOS 已经在用，tvOS 接下来接入。

| 模块 | 内容 |
| --- | --- |
| `HongguoCore` | 网络、签名、设备身份、取源、清晰度与 CDN 候选、解析、解密、持久化。不依赖 UI。 |
| `HongguoPlayback` | 把 `PlayInfo` 变成可播放的 `AVPlayerItem` 加 loader：红果的 `EpisodeResolver`、`StreamingResourceLoader`、`MediaPrefixCache`。loader 由 App 持有到换集或关闭。iOS 的 `BookMallFeed`（首页推荐流，`AppFeed` 只剩它用的行解析）、`LocalCastServer`、`SeriesCredits` 暂时也在这里，接 tvOS 时再定归属。 |
| `AppLogic` | 各 App 共用的纯规则，不碰界面和网络：信息流和连播推进、手势换算、定时关闭、写操作同步、历史与点赞合并、首页曝光去重、每集断点、分页请求等（原 iOS 仓库的 `Logic/`，模块名不变）。 |
| `HongguoModels` | 各 App 共用的模型，不碰界面：`DramaBackend`（协议、真实实现 `LiveBackend`、离线样例 `FixtureBackend`）、`AccountModel`（登录态，收藏点赞预约历史，按记录排队的写操作，会话隔离）、`LibraryModel`（本机和账号切换与失败回滚、云端历史合并、不感兴趣、首页曝光去重、每集断点、3 分钟同步循环）、`LoginModel`（扫码登录循环）、`LaunchArguments`（通用启动参数）、页面模型（`TheaterModel`、`RankingModel`、`NewDramaModel`、`CalendarModel`、`SeriesDetailModel`、`CelebrityModel`、`CommentListModel`、`EpisodePanelModel`，iOS 已改用；`SearchModel`、`MeModel`，iOS 待改用）、`AccountRoster`（一台设备上的多个账号和切换，tvOS 在用，iOS 待接）。原在 iOS App 里，搬过来时规则不变。 |
| `HongguoPlayerKit` | iOS 和 tvOS 共用的播放器（UIKit，macOS 上为空模块）：`PlayerEngine` 和图层视图（`VideoSurface`、`SlotView`、`PlayerLayerView`）、`PlaybackSession`、`FeedModel`、`LandingCache`、封面缓存 `CoverImage`、`DanmakuLayer`、`CoverTint`、表情 `EmoticonCatalog`（表情图是本包资源）、`CountText`。只有 iOS 有的能力（已下载文件、ByteVC2 转码流、投屏发布、小窗）走 `PlayerHooks` 四个可选钩子，iOS 启动时装上，tvOS 不装；不装时只有 ByteVC2 的分集落到「此剧集暂不支持」。 |

手势、页面布局和控制层留在各 App。

落盘位置统一走 `StorageRoot`：默认 Application Support（Mac、iOS 不用设置），tvOS 启动时调一次 `StorageRoot.configure(base:mirror:)` 指向 Caches，并把设置和最近 40 部剧的进度镜像进 `UserDefaults`。这是位置，不是行为开关。

## 一套逻辑，没有平台开关

三端（Mac、iOS、tvOS）走完全相同的代码路径，包里没有按平台切换的开关，App 启动时也不用设任何东西。

| 环节 | 唯一的做法 |
| --- | --- |
| 取源 | `AuthenticatedPlaybackSource` 通过 App 播放模型取源，使用固定 iPhone UA。播放、预热与预取共用设备注册记录。 |
| 分集列表 | `SeriesService.episodes` 从 App 详情生成分集，创作者合集走合集详情。 |
| 设备身份 | `PersistentAppDevice` 保存注册记录，注册与续期仍声明 Android 客户端。搜索、书城、账号和社交请求也使用 Android 资料；播放模型的外层参数使用 iPhone 资料。 |
| 目录和榜单 | 只有 App（`CatalogService` 调 `DiscoveryAccess`），不读官网页面。 |
| 搜索 | 只有 App 搜索 `AppSearchService`（翻页用它的游标），没有官网搜索、放宽关键词或上新补搜。`NewReleaseService` 是单独的近 7 天上新列表，不参与搜索。 |
| 评论 | 只有 App 评论接口（`EpisodeSocialService.commentsPage`，`EpisodeCommentService` 和 `load` 都用它）。 |
| 官网 | 网页登录、扫码和会话验证使用官网。分享短链可通过跳转或页面内容提取剧集 ID。 |
| 网络防护 | `URLGuard` 一种行为：Fake-IP 和 ULA 都算代理地址，红果自己的 https 域名先放行、后台用 DoH 复核（复核不是公网就从此拦截），其他域名要等 DoH（2 秒），缓存最长 300 秒。真实的内网、回环、链路本地地址一律拦截。 |

已经删掉、不要再加回来的：安卓配置的播放请求、App 快速通道、App 排队通道和 551 签名、未签名的旧接口、官网 360p 备用通道、官网网页片源、网页和旧接口的分集列表兜底、匿名注册的临时设备、`PlatformBehavior`、播放时去掉 Cookie 的匿名重试和换新设备、官网目录和榜单页、官网搜索和 `HongguoSearch` 的补搜链、播放页网页评论、弹幕的本机随机身份（`danmaku-client.json`）、评论和目录的随机设备、`AppFeed` 的分类列表信息流。

## 进度

1. 已完成：Mac 的核心移进来，`macos/` 用本地路径依赖。
2. 已完成：并入 iOS 的核心和播放内核（基线 iOS 382e2c2），iOS 用子模块指向这里。
3. Mac 和 iOS 共用 App 播放、目录、搜索和评论接口。
4. 已完成：存储根目录可注入（`StorageRoot`）、iOS 的纯规则（`AppLogic`）、共享模型（`HongguoModels`）和播放器（`HongguoPlayerKit`）下沉；tvOS App（`../tvos`）在这些之上只写界面。
5. 之后再定：iOS 的搜索和「我的」改用 `SearchModel`、`MeModel`，iOS 接入 `AccountRoster`；Mac 播放器是否换用共享播放器。

## 测试

```bash
cd HongguoKit
swift test                                   # 离线测试（iOS 和 tvOS 用 xcodebuild -scheme HongguoKit-Package -destination 'generic/platform=iOS' build）
HONGGUO_LIVE=1 swift test --filter SourceLiveTests   # 线上测试：播三集加一次搜索，会真的请求红果接口
HONGGUO_LIVE=1 HONGGUO_PROBE="关键词" swift test --filter EmptySourceProbeLiveTests  # 片源为空时的探针
HONGGUO_PROBE=playback swift test --filter PlaybackProbeTests  # 播放内核的线上探针
```
