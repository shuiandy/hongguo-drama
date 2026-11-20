# 红果短剧 原生 macOS 版

这个仓库现在只保留原生 Mac 客户端，代码在 [`macos/`](macos/README.md)：Swift / SwiftUI / AVKit，
macOS 14 及以上。构建、结构和安全说明见 `macos/README.md`。

```bash
cd macos
swift test
./scripts/build-app.sh
```

## 与上游的关系

本仓库 fork 自上游的 Electron 版红果短剧下载器（来源见 `NOTICE`）。上游的 Electron、Android、
Docker 代码以及它们的构建和发布脚本已经从工作区移除，不再在这里维护；需要对照时请看上游仓库，
或本仓库的 git 历史（移除之前的提交）。

仍然来自上游的只有：

- `LICENSE`、`NOTICE`、`THIRD-PARTY-NOTICES.md`：许可证与来源声明，按 GPL 3.0 保留。
- `macos/scripts/librempeg/`：ByteVC2 组件 librempeg 的构建脚本和补丁，原样保留，
  由 `macos/scripts/build-librempeg.sh` 调用。

`macos/scripts/gen-*-vectors.cjs` 用上游参考实现重新生成测试向量，运行前把 `HONGGUO_UPSTREAM`
指向一份上游代码。日常构建和测试不需要它们，向量已经提交在 `macos/Tests` 里。

## 许可证

GPL 3.0，见 `LICENSE`。
