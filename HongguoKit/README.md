# HongguoKit

原生 App 共用的 Swift 包。现在只有 macOS 在用；iOS 和 tvOS 会按下面的顺序接进来。

| 模块 | 内容 |
| --- | --- |
| `HongguoCore` | 网络、签名、设备身份、取源、清晰度与 CDN 候选、解析、解密、持久化。不依赖 UI。 |
| `HongguoPlayback`（第 3 步加入） | 把 `PlayInfo` 变成可播放的 `AVPlayerItem` 加 loader：红果的 `EpisodeResolver`、`StreamingResourceLoader`、`MediaPrefixCache`。loader 由 App 持有到换集或关闭。 |

播放器、手势、画中画、页面布局留在各 App。

## 迁移顺序

第一阶段只共享代码，Mac 和 iOS 各自保留现在的播放行为和取源顺序。

1. 把 `macos/Sources/HongguoCore` 和它的测试原样移到这里，`macos/` 改为本地路径依赖。Mac 行为不变。
2. 并入 iOS 仓库 `Shims/HongguoCore` 和 `Playback/` 的代码。iOS 新增的文件原样加入；两端都有的文件逐项合并，确实冲突的策略（例如 `URLGuard` 在代理虚拟地址下对服务域名的处理）做成显式开关，各 App 启动时设成现在的值。
3. iOS 的子模块指向这里，删掉已经迁走的 shim，用完整 App 构建验收首页、播放、预取和投屏。
4. 加入 tvOS 平台，先用最小 Apple TV App 验证普通 H.264 剧集。
5. 统一取源顺序、Mac 是否换用 iOS 的加载器，用同一组样本比较首帧时间、成功率和清晰度之后再单独决定。

## 测试

```bash
cd HongguoKit
swift test                                   # 离线测试
HONGGUO_LIVE=1 swift test --filter SourceTimingLiveTests   # 线上测试，会真的请求红果接口
```
