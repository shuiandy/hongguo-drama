# 观看进度回传红果账号（原生 Mac 版）

2026-11-18 研究结论与内核实现说明。

## 结论

可行。红果官方客户端把“观看历史”和“续播进度”存在两张表里，回传需要两个接口都写：

| 用途 | 接口（POST，主机 `api5-normal-sinfonlinea.fqnovel.com`） |
| --- | --- |
| 观看历史（`read_history/list/v1` 读到的那张表） | `/reading/bookapi/read_history/update/v1/` |
| 续播进度（App 里“继续观看”） | `/reading/bookapi/read_progress/upload/v1/` |

鉴权与现有的云端历史读取完全相同：已注册的匿名设备身份 + 红果网页登录 Cookie + App 签名（X-Gorgon、X-Medusa、X-Helios 等）。区别是 POST 带 JSON body，body 的 MD5 要参与 hash 分支、Gorgon 和 Medusa，并放进 `x-ss-stub` 头。签名档沿用 hongguoTV 写接口用的 7.3.9.32。

### 请求体

历史：

```json
{"update_datas":[{"book_id":<剧ID数字>,"book_id_str":"<剧ID>","book_type":2,"vid":<分集ID数字>,
  "vid_index":<第几集>,"chapter_index":<第几集>,"read_timestamp_ms":<观看时间毫秒>,"update_timestamp_ms":0,
  "current_play_position":<位置毫秒>,"player_accumulate_total_time":<位置毫秒>,"duration":<时长毫秒>,
  "episode_cnt":<总集数>,"is_delete":false,"use_soft_delete":false,"genre_type":2150,"book_name":"…","thumb_url":"…"}]}
```

续播：

```json
{"books":[{"book_id":"<剧ID>","item_id":"<分集ID>","vid_index":<第几集>,"current_play_time":<位置毫秒>,
  "current_total_time":<时长毫秒>,"episode_count":<总集数>,"read_timestamp_ms":<观看时间毫秒>,"book_type":2,
  "progress_rate":"0.1293","player_cumulative_total_duration":<位置毫秒>}],"write_mode":1}
```

19 位 ID 必须原样写成 JSON 数字，不能经过 Double。成功判定：顶层 `code` 为 0，且 `data` 里没有非零 `error_code`。

### 依据

* N3urda/hongguoTV `kotlin-tv/core/.../CloudAccount.kt` 的 `upload()`（本项目签名代码的来源）。
* dddmiku/hongguo-tv `ProgressContract.java`（历史 + 续播两段 body，先写历史再写续播）。
* it00021hot/hongguo-desktop 的 APK 接口清单：两个接口都是 POST。

未自行抓包；首次真实账号写入需要账号所有者同意。

## 风险

* 字段不被接受时可能产生一条异常历史，可用同一接口 `is_delete:true` 或在 App 内删除。
* 设备身份是模拟安卓，写操作比读更敏感；目前读接口长期正常，两个开源项目未见封号反馈，风险低但非零。
* 写请求不自动重试（超时的写可能已经生效），同一集位置变化小于 5 秒不重复上报。

## 内核接口

* `AppSettings.cloudProgressSync`，默认 `false`。
* `AccountService.reportProgress(_:force:)`：先写历史、再写续播，两步都确认才返回 `.synced`；未登录或重复位置返回 `.skipped`；任何一步未确认抛出错误且不记为已上报。
* 建议界面在切集、暂停、关闭播放器时调用，且仅对红果来源、开关打开时调用。
* 真实账号验证：`HONGGUO_LIVE_PROGRESS=rewrite swift test --filter AccountProgressLiveTests`，只改写云端最新一条已有记录（同集同位置，时间改为现在）。
