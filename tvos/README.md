# 红果短剧 tvOS 版

Apple TV App（tvOS 26+），只写界面、焦点和遥控器交互。取源、选集、设备身份、同步规则、页面数据和播放器全部来自共用包 `../HongguoKit`（`HongguoCore`、`HongguoPlayback`、`AppLogic`、`HongguoModels`、`HongguoPlayerKit`），和 Mac、iOS 版是同一份代码，没有平台开关。iOS 才有的能力（已下载文件、ByteVC2 转码、投屏、小窗）是播放器的可选钩子，tvOS 不装：只有 ByteVC2 的分集显示「此剧集暂不支持」并在 2 秒后播下一集。

## 页面

| 页面 | 说明 | 共享模型 |
| --- | --- | --- |
| 选择账号 | 启动时本机存过账号就先显示：圆形头像一排、最近用的默认焦点、添加账号、不登录使用、长按移除 | `AccountRoster`、`AccountModel` |
| 推荐 | 左信息、中视频、右下一部；「观看完整剧集」是唯一焦点，上下换剧，按下进完整剧原地接着播；播放时标签栏淡出 | `FeedModel` |
| 剧场 | 照 iOS 剧场的顺序：一行胶囊（真人剧/漫剧/AI 剧、题材筛选、追剧日历、新剧），下面是所选分类的网格；排行只在顶部标签 | `TheaterModel`、`NewDramaModel`、`CalendarModel` |
| 排行 | 左侧分类和榜单，右侧带名次的海报网格 | `RankingModel` |
| 追剧 | 观众留下的全部内容，各一排货架：收藏、历史（带进度，长按取消收藏或删除记录）、点赞、预约 | `MeModel`、`LibraryModel` |
| 搜索 | 照 iOS 新搜索页的顺序（不放排行/追剧日历/上新入口，每个功能只有一个入口）：历史、猜你想搜、三个榜单合在一张卡里切换（查看更多手动加载）、结果网格；搜索框提示轮换热搜榜，空框提交搜提示词，榜单项能播进播放器、未上线进待上线详情 | `SearchModel`、`SearchHintRule`、`RankItemDestination` |
| 我的 | 像系统设置：左边账号信息（不拿焦点），右边一列整行选项，上下键能走到每一行：扫码登录/退出登录、切换账号、默认清晰度、默认倍速、弹幕、自动连播；按一下切到下一个值。和 iOS 一样没有云端观看记录开关，登录后观看历史、收藏、点赞、预约总是和账号双向同步（共用 `LibraryModel.syncAccount`：回到前台同步一次，之后每 3 分钟一次） | `AccountModel`、`LibraryModel` |
| 详情 | 左封面右信息、每行 12 个集数格子按 30 集分段、演员（进演员页）、相关推荐 | `SeriesDetailModel`、`CelebrityModel` |
| 播放器 | 9:16 全高居中，两侧封面主色；选集、评论（只读）、弹幕、倍速、画质；最后 5 秒下一集 | `PlayerEngine`、`PlaybackSession`、`EpisodePanelModel`、`CommentListModel` |
| 扫码登录 | 大二维码、状态、过期自动换码、跳过；成功后加入账号名册 | `LoginModel` |

## 播放器的遥控器规则

三层，一次只有一层接遥控器，返回键永远往外退一层：

1. 只有画面：按下触控板或播放键 = 暂停并唤出控制层（焦点在进度条）；点按左右 = 后退/前进 10 秒并闪一下进度条；上下（点按或滑动）= 唤出控制层（焦点在「选集」）；返回键 = 退出播放器。手指在触控板上左右滑动不做任何事，进度不会被误拖。
2. 控制层：进度条和它下面的一行按钮（选集、评论、弹幕、倍速、画质）都是普通焦点项，由系统焦点引擎移动。只有焦点在进度条上时，左右才改进度（每步 10 秒），按下 = 播放/暂停；在按钮行上左右只在按钮之间移动。返回键 = 收起控制层。播放中 5 秒不操作自动收起。
3. 面板（选集、评论、倍速、画质）：返回键 = 关闭面板，回到画面。面板右上角有「返回键关闭」提示。

画面层由 `RemoteSurface`（UIKit 视图，只收按键和上下滑）接管；控制层或面板出现时它不再可聚焦，所以按钮有焦点时没有任何手势在监听。

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
scripts/build-sim.sh --test
```

`--test` 跑单元测试和 UI 测试（选模拟器的规则和 `--run` 一样，`HONGGUO_TV_UDID` 可指定），跑完关掉模拟器；`shoot.sh` 拍完也会关。Apple TV 模拟器开着闲置几分钟就进屏保，屏保进程 IdleScreen 在模拟器里会因内存申请失败反复崩溃，macOS 每次都弹崩溃报告，所以用完要关。`--run` 之后自己执行 `xcrun simctl shutdown <udid>`；要留着就设 `HONGGUO_KEEP_SIM=1`。

签名用付费个人团队的自动签名；和 iOS 版一样，团队 id 不进仓库，编真机时在命令行传 `DEVELOPMENT_TEAM`。
