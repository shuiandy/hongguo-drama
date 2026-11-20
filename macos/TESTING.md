# 原生 macOS 版实测记录

不记录登录凭据、设备身份或带签名的媒体地址；片源只记主机名。

## 2026-11-18 App 片源移植

环境：Apple Silicon，macOS 27.2，Swift 6.4.2，Xcode 27.2（27B52）；本机开着 Surge（Fake-IP），未改动。

- `swift build` / `swift build -c release`：干净构建 0 错误、0 警告。
- `swift test`：38 项全部通过。其中签名向量 8 项：SM3、v5 f13（上游 32 组）、carrier（上游 4 组）、
  v5 完整签名（node 生成 3 组）、551 Argus/Ladon（2 组）、内容密钥与片源地址解密、gzip 往返、域名白名单。
- `./scripts/build-app.sh` 打包，`codesign --verify --strict` 通过（ad-hoc）。

真实网络冒烟（临时测试文件，测完删除）：

| 样本 | 结果 |
| --- | --- |
| 热播榜前 5 + 真人剧前 5，各取第 1 集 | 10/10 成功；全部 source=app、HEVC、加密，主机 v3-reading-videocdn302.qznovelvod.com |
| Range 0-1023 | 10/10 返回 206，含 ftyp（isom） |
| 解密后用 AVURLAsset 读取 | 抽查 2 集：时长 96.9 s / 71.8 s，可播放，编码 hvc1，1080×1924 / 1080×1920 |
| 《穿越八零，我把娘俩宠成宝》第 1–6 集（官网只公开 5 集） | 6/6 成功，第 6 集 Range 206 + ftyp |

应用实测：在主界面打开《少夫人来自东北3》，点第 6 集，播放器窗口显示“片源：App”并开始播放。
播放前把应用音量设为 0，全程静音；测完删除了应用自己的缓存和设置目录。

以下路径本轮没有在真实网络中触发，只有单元测试或合成数据覆盖：备用主机重试、551 旧接口重试、
`fallback_api`、`key_seed` 片源地址解密，以及未加密 App 片源的流式播放。
