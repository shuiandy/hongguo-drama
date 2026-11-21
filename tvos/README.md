# 红果短剧 tvOS 版

Apple TV App（tvOS 26+），只写界面、焦点和遥控器交互。取源、选集、设备身份、同步规则、页面数据和播放器全部来自共用包 `../HongguoKit`（`HongguoCore`、`HongguoPlayback`、`AppLogic`、`HongguoModels`、`HongguoPlayerKit`），和 Mac、iOS 版是同一份代码，没有平台开关。iOS 才有的能力（已下载文件、ByteVC2 转码、投屏、小窗）是播放器的可选钩子，tvOS 不装：只有 ByteVC2 的分集显示「此剧集暂不支持」并在 2 秒后播下一集。

## 页面

| 页面 | 说明 | 共享模型 |
| --- | --- | --- |
| 选择账号 | 启动时本机存过账号就先显示：圆形头像一排、最近用的默认焦点、添加账号、不登录使用、长按移除 | `AccountRoster`、`AccountModel` |
| 推荐 | 左信息、中视频、右下一部；「观看完整剧集」是唯一焦点，上下换剧，按下进完整剧原地接着播；播放时标签栏淡出 | `FeedModel` |
| 剧场 | 新剧和追剧日历入口、继续观看大卡、真人剧/漫剧/AI 剧三排货架 | `TheaterModel`、`NewDramaModel`、`CalendarModel` |
| 排行 | 左侧分类和榜单，右侧带名次的海报网格 | `RankingModel` |
| 追剧 | 收藏和历史两排带进度的货架，长按取消收藏或删除记录 | `MeModel`、`LibraryModel` |
| 搜索 | 系统 `.searchable`、历史、猜你想搜、热搜榜/预约榜/热点话题榜、结果网格 | `SearchModel` |
| 我的 | 账号卡（扫码登录、退出登录、切换账号）、点赞、预约、设置 | `MeModel`、`LibraryModel` |
| 详情 | 左封面右信息、每行 12 个集数格子按 30 集分段、演员（进演员页）、相关推荐 | `SeriesDetailModel`、`CelebrityModel` |
| 播放器 | 9:16 全高居中，两侧封面主色；选集、评论（只读）、弹幕、倍速、画质；最后 5 秒下一集 | `PlayerEngine`、`PlaybackSession`、`EpisodePanelModel`、`CommentListModel` |
| 扫码登录 | 大二维码、状态、过期自动换码、跳过；成功后加入账号名册 | `LoginModel` |

遥控器（播放器）：按下触控板或播放键暂停并唤出控制层；左右点按 ±10 秒；左右滑拖进度；下滑或下键开选集（控制层显示时移到按钮行）；返回键依次收面板、收按钮、退出。

## 目录

```
project.yml           XcodeGen 工程描述（.xcodeproj 和 App/Info.plist 是生成物，不入库）
App/Sources/          入口和顶部标签、Components/、Pages/、Player/
App/Resources/        资源（分层图标和 Top Shelf 图由 iOS 图标生成）
UnitTests/            单元测试（共享播放器在 tvOS 上不装钩子时的行为）
UITests/              UI 测试（离线、静音，经 freshLaunch 启动）
scripts/build-sim.sh  编到 Apple TV 模拟器（--run 装上并离线静音启动）
scripts/shoot.sh      按启动参数逐页截图到 docs/screenshots/
```

## 存储

Apple TV 没有持久的本地存储。启动时第一件事是 `StorageRoot.configure(base: Caches, mirror: .standard)`：所有落盘文件进 Caches（系统可能清掉），设置和最近 40 部剧的进度另外镜像进 `UserDefaults`（tvOS 给每个 App 500 KB）。播放日志也写在 Caches。离线样例运行不写镜像。每个账号的登录各存一条钥匙串（`HongguoDrama.account.roster`），当前登录仍是原来那条。

## 启动参数

| 参数 | 作用 |
| --- | --- |
| `-HongguoOfflineFixtures YES` | 用内置示例数据，不发任何网络请求 |
| `-HongguoMuted YES` | 静音播放，不占 Mac 的音频输出 |
| `-HongguoRoute <名称>` | `recommend` `theater` `ranking` `following` `search` `me` `detail` `player` `player-controls` `player-episodes` `accounts`（离线放 3 个内存假账号） `new` `calendar` |
| `-HongguoSeries <剧 id>` | `detail`、`player*` 打开的剧；不给就用离线第一部样例或热播榜第一部 |
| `-HongguoAccountPreview YES` | 离线时显示一个假的已登录账号 |
| `-HongguoShowLogin YES` | 启动后打开扫码登录 |

## 构建和测试

```bash
cd tvos
scripts/build-sim.sh --run
scripts/shoot.sh <udid> <label>
xcodebuild -project HongguoDramaTV.xcodeproj -scheme HongguoDramaTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

签名用付费个人团队的自动签名；和 iOS 版一样，团队 id 不进仓库，编真机时在命令行传 `DEVELOPMENT_TEAM`。
