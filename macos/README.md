# 红果短剧 原生 macOS 版

用 Swift / SwiftUI / AVKit 从头实现的原生 Mac 客户端，复用 Electron 版使用的官网与 App 接口，
目标是替代 Electron 版在 Mac 上的播放器、悬浮小窗和整体体验。代码与 Electron 版相互独立，
位于仓库的 `macos/` 目录。

## 当前进度（第一阶段 MVP）

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 分类浏览（真人剧 / 漫剧 / AI 剧 + 题材筛选） | 已完成 | 官网 `_ROUTER_DATA`，无限滚动 |
| 榜单（总榜 / 真人 / 漫剧 / AI） | 已完成 | 流式 SSR 数据，带 HTML 卡片兜底 |
| 搜索 | 已完成 | 官网 `/api/search/result`，记住最近搜索 |
| 分享链接 / 剧集编号直达 | 已完成 | 手动跟随跳转，每一跳都过 SSRF 校验 |
| 剧集详情、简介、评分、评论 | 已完成 | 官网公开数据 |
| 播放：官网明文片源 | 已完成 | 自有 URLSession 流式加载，AVPlayer 硬解 |
| 播放：App 签名片源（player/v1） | 已完成 | 移植 `app-source.js` 播放路径：匿名设备注册（仅内存）、v5 签名，失败时换官方备用主机，再走一次 551 签名旧接口 |
| 播放：旧 App 接口加密片源 | 已完成 | 最后的回退；加密片源下载后 CENC 解密到本地缓存再播放 |
| 原生播放控件、全屏、画中画 | 已完成 | `AVPlayerView`，系统级 PiP |
| 无边框悬浮小窗 | 已完成 | 置顶、跨桌面、按视频比例缩放、拖动、双击还原 |
| 无标题栏播放器窗口 | 已完成 | 透明标题栏，悬停显示顶栏 |
| 自动连播、倍速、长按空格 2 倍速 | 已完成 | |
| 观看记录与续播 | 已完成 | `~/Library/Application Support/HongguoDrama` |
| 深浅色主题 | 已完成 | 跟随系统或手动 |
| App 搜索 / 目录 / 账号接口签名（X-Gorgon 等） | 未移植 | 播放不需要；搜索与目录走官网 |
| 弹幕、官网账号登录 | 第三阶段 | |

## 对照 Electron 版补齐的功能

| 功能 | 说明 |
| --- | --- |
| 热播推荐、随机抽剧、上新日历 | 侧栏「发现」分区；上新日历按首播日期列出看过、打开过或收藏的剧。缺日期的剧在打开日历页时从公开详情页补查（逐部进行，约每秒一部，每次启动最多 60 部，只读不写云端） |
| 红果 App 搜索、新剧补搜 | 设置 > 片源里可设为优先；官网搜不到的新剧会用 App 搜索补上 |
| 分集小红心 | 分集格右键或播放器控制条，只存在本机 |
| 查找下一季 | 剧集详情页，按剧名搜索同系列的其他季 |
| 弹幕备用来源 | 没有官方弹幕时用本集评论滚动显示，设置 > 弹幕可改来源 |
| 合并导出 | 用 AVFoundation 把已下载的分集合成一个 MP4，不需要 FFmpeg；快速合并不重新编码 |
| 下载到 NAS、整剧资料 | 选一个已挂载的共享文件夹，按 `剧名/Season 01/剧名 S01E001.mp4` 存放，并写入 `tvshow.nfo`、封面、简介和分集 NFO |
| ByteVC2 兼容转换 | 只有 ByteVC2 片源的分集先下载再转成 H.264。需要单独的 `librempeg` 组件（AGPL 3.0）：`./scripts/build-librempeg.sh` 构建后 `build-app.sh` 会自动打包；没有时回退到已安装的 Electron 版里的那一份 |
| 网络代理 | 设置 > 网络：直连（默认）、跟随系统、手动 HTTP / SOCKS5；密码存钥匙串 |
| 应用内更新 | 发布里有 `HongguoDrama-*.zip`（`ZIP=1 ./scripts/build-app.sh` 生成）且带 SHA 256 摘要时可一键下载安装；安装前校验摘要和代码签名，签名身份不一致时只提供打开发布页 |

## 构建

需要 macOS 14 及以上、Xcode 15.3 或更新版本（或对应的 Command Line Tools）。

```bash
cd macos
swift test                     # 核心库单元测试
./scripts/build-app.sh         # 生成 build/HongguoDrama.app（本机架构，ad-hoc 签名）
open build/HongguoDrama.app
```

通用二进制与正式签名：

```bash
ARCHS="arm64 x86_64" SIGN_IDENTITY="Developer ID Application: <名字> (<TEAMID>)" ./scripts/build-app.sh
```

也可以直接用 Xcode 打开 `macos/Package.swift` 调试。

## 结构

```
HongguoKit/                 Mac、iOS、tvOS 共用的 Swift 包（见 HongguoKit/README.md）
  Package.swift
  Sources/HongguoCore/      网络、解析、解密、持久化（不依赖 UI，可单测）
    URLGuard.swift          SSRF 防护（公网地址校验、Fake-IP 时用 DoH 复核）
    HTTPClient.swift        URLSession 封装，每一跳重定向都校验
    HTMLData.swift          只解析页面里的 JSON 字面量，不执行任何远端脚本
    SearchService.swift     官网搜索
    CatalogService.swift    分类与榜单
    SeriesService.swift     分集、取源（App 快速通道 → App 排队通道 → 旧接口 → 官网）、详情、分享链接
    FastAppPlaybackSource.swift  App 快速通道：内存里复用一个匿名设备身份，批量预取
    AppSource.swift         App 播放取源：排队限速、选流、密钥与片源地址解密、域名白名单
    PlaybackDevice.swift    匿名播放设备注册（只在内存，失败冷却 10 秒）
    PlaybackSignerV5.swift  player/v1 的 v5 签名（Medusa / Helios）
    PlayerSignature551.swift 旧接口重试用的 Argus / Ladon 签名
    AppCrypto.swift         SM3、AES-CBC、gzip 等底层工具
    LegacyAPI.swift         未签名的旧 App 接口（最后的回退）
    CencDecryptor.swift     spade_a 取密钥、CENC MP4 解密与 moov 重建
    PlaybackCache.swift     加密片源的解密缓存
    LibraryStore.swift      观看记录与设置
  Tests/HongguoCoreTests/   解析、解密、签名（含 Electron 版生成的向量）、SSRF、存储
macos/
  Package.swift             依赖 ../HongguoKit
  Sources/HongguoDrama/     SwiftUI + AppKit 应用
    Views/                  侧边栏、分类、搜索、详情、观看记录、设置
    Player/                 播放控制、流式加载、播放器窗口、悬浮小窗
  scripts/gen-signing-vectors.cjs  用 src/native 的 JS 实现重新生成签名测试向量
```

签名测试同时读取 `src/native/fixtures/playback-v5-vectors` 下的上游向量，因此需要在完整仓库里运行。

## 安全说明

* 所有来自远端数据的地址（片源、分享链接、跳转）都经过 `URLGuard`：只允许 http/https、
  不允许内嵌账号密码、主机名与解析结果必须是公网地址。系统 DNS 只返回 Fake-IP
  （198.18.0.0/15，Surge/Clash 等代理常见）时，会用固定的 DoH 解析复核真实地址。
* App Transport Security 保持开启，http 片源会先升级为 https。
* 播放流量走应用自己的 URLSession（不存 Cookie、不带账号信息），AVPlayer 只看到私有的
  `hgstream://` 地址。
* 代码中没有任何账号凭据；接口里的设备参数是协议常量。App 取源时注册的匿名设备身份只保存在内存，
  不写盘，每次取源重新注册；注册失败后 10 秒内不再重试。所有取源请求排成一队、间隔至少 1 秒，
  遇到 403 / 429 / 业务拒绝会停止已排队的请求。
* App 返回的片源地址只接受 qznovelvod.com / fqnovelvod.com / douyinvod.com 的 HTTPS 地址，并再过
  `URLGuard`；App 接口本身只允许 fqnovel.com / snssdk.com，带签名的请求不跟随跳转。
* 已知限制：DNS 校验与实际连接之间存在理论上的 DNS 重绑定窗口（URLSession 不支持固定 IP 连接），
  与 Electron 版相比少了 socket 级别的地址校验。

## 快捷键（播放器窗口或小窗聚焦时）

| 按键 | 功能 |
| --- | --- |
| 空格 | 播放 / 暂停，长按临时 2 倍速 |
| ← / → | 快退 / 快进 5 秒 |
| ↑ / ↓ | 上一集 / 下一集 |
| S / D | 减速 / 加速 |
| A | 切换自动连播 |
| F | 全屏 |
| M | 悬浮小窗 |
| E | 显示 / 隐藏选集 |
| Esc | 退出全屏或小窗 |
