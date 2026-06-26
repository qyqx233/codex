# ipatch 分支改动总结

本分支对日志子系统做了两件事:**收紧默认日志过滤** + **给原始 payload 加环境变量开关**。同步上游时若这些文件冲突,优先保留本分支的语义,再把上游其它改动合并进来。

## 设计意图

1. **默认日志量太大**:`default_filter` 原本把全局默认设为 `TRACE`,导致 OpenTelemetry SDK、`hyper_util` 连接池、`tokio_tungstenite` 帧层、`notify` 的 inotify 事件等大量噪声落盘。改为默认 `WARN`,并由 `CODEX_LOG_LEVEL` 覆盖。
2. **payload 含敏感数据且体量大**:websocket 请求体和 SSE 事件体原本无条件 `trace!`,改为默认只记 `bytes` 长度,仅在 `CODEX_LOG_RAW_PAYLOADS` 存在时才输出原文。
3. **`tracing-log` 兼容层会绕过 `Targets` 缓存**:`on_event` 里加一条硬兜底,target == `"log"` 直接 drop,不再仅针对 `opentelemetry_sdk` 的 TRACE/DEBUG。

## 文件改动

### `codex-rs/codex-api/src/endpoint/responses_websocket.rs`
- 位置:`send_websocket_request` 内,约第 782 行。
- 原代码:`trace!("websocket request: {request_text}");`
- 新代码:先 `trace!(bytes = request_text.len(), "websocket request sent")`,再在 `CODEX_LOG_RAW_PAYLOADS` 开启时 `trace!("websocket request payload: {request_text}")`。
- 冲突处理:若上游重构了请求发送路径,保留"默认只记长度、env 开关控制原文"这条语义。

### `codex-rs/codex-api/src/sse/responses.rs`
- 位置:`process_sse_with_treatment` 内,约第 504 行。
- 删除无条件的 `trace!("SSE event: {}", &sse.data);`。
- 解析失败分支:debug 只记 `bytes` 长度,payload 受 `CODEX_LOG_RAW_PAYLOADS` 控制。
- 解析成功后:`trace!(kind = %event.kind, bytes = sse.data.len(), "SSE event received")`,payload 同样受开关控制。
- 冲突处理:若上游调整了 SSE 事件处理顺序,确保"成功事件 trace 带 kind+bytes、失败事件 debug 带 bytes、原文统一受 env 开关"的形状不变。

### `codex-rs/state/src/log_db.rs`
两处改动:

#### `default_filter()`(约第 51 行)
- 新增:`CODEX_LOG_LEVEL` 环境变量解析为 `LevelFilter`,默认 `WARN`(原为 `TRACE`)。
- 保留:`codex_otel.log_only`、`codex_otel.trace_safe` 全 OFF;`log` 全 OFF。
- 新增收紧到 WARN:`opentelemetry_sdk`、`opentelemetry_appender_tracing`、`hyper_util`、`tokio_tungstenite`、`h2`、`tower`。
- 注释里说明了每类 target 为何要过滤,合并时保留注释。

#### `on_event()`(约第 199 行)
- 原代码:只对 `opentelemetry_sdk` 的 TRACE/DEBUG 短路返回。
- 新代码:对任何 `metadata.target() == "log"` 的事件直接 return,作为 `Targets` 过滤的硬兜底。
- 冲突处理:若上游改了 `MessageVisitor` 或事件处理流程,这条"target==log 直接 drop"的硬兜底要保留在 `on_event` 入口附近。

### `codex-rs/state/src/log_db_filter_tests.rs`
- 原测试 `sqlite_sink_drops_low_level_opentelemetry_sdk_logs` 拆成两个:
  - `default_filter_drops_telemetry_and_dependency_noise`:纯 filter 单元测试,用 `would_enable` 断言各 target 在不同 `Level` 下的启用情况。
  - `sqlite_sink_honors_default_filter`:端到端测试,subscriber 改用 `default_filter()`,断言只保留 `codex_state` 的 TRACE/INFO 事件。
- 导入从 `tracing_subscriber::filter::Targets` 改成 `tracing::Level`。
- 冲突处理:若上游新增了别的 filter 测试,保留这两个新测试的语义;断言清单见文件内 `assert!` 列表。

## 环境变量约定

- `CODEX_LOG_LEVEL`:覆盖 `default_filter` 的全局默认级别,默认 `WARN`。
- `CODEX_LOG_RAW_PAYLOADS`:任意值即生效,开启后 websocket 请求体和 SSE 事件体原文会以 `trace!`/`debug!` 输出。

## 同步上游 checklist

1. `git fetch upstream && git checkout ipatch && git rebase upstream/<主干>`(或 merge)。
2. 冲突集中在上述四个文件。逐文件按上面"冲突处理"注释保留本分支语义。
3. 冲突解决后:
   - 在 `codex-rs` 目录跑 `just fmt`。
   - `just test -p codex-state`(覆盖 log_db 及其 filter 测试)。
   - `just test -p codex-api`(覆盖 SSE/websocket 路径,若上游改了相关测试)。
4. 检查 `read.md` 是否需要保留:它是未跟踪的临时文件,不进 commit。
