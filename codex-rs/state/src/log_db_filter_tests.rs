use pretty_assertions::assert_eq;
use tracing::Level;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use uuid::Uuid;

use super::*;

#[tokio::test]
async fn default_filter_drops_telemetry_and_dependency_noise() {
    let filter = default_filter();

    // Telemetry-only targets should never reach SQLite.
    assert!(!filter.would_enable("codex_otel.log_only", &Level::TRACE));
    assert!(!filter.would_enable("codex_otel.log_only", &Level::INFO));
    assert!(!filter.would_enable("codex_otel.trace_safe", &Level::TRACE));

    // OpenTelemetry SDK internals should be fully suppressed.
    assert!(!filter.would_enable("opentelemetry_sdk", &Level::INFO));
    assert!(!filter.would_enable("opentelemetry_sdk", &Level::TRACE));
    assert!(!filter.would_enable("opentelemetry_appender_tracing", &Level::TRACE));

    // `log` compatibility chatter (inotify, etc.) should be suppressed.
    assert!(!filter.would_enable("log", &Level::TRACE));

    // HTTP/WebSocket internals: warnings/errors stay, debug/trace go.
    assert!(!filter.would_enable("hyper_util", &Level::DEBUG));
    assert!(filter.would_enable("hyper_util", &Level::WARN));
    assert!(!filter.would_enable("tokio_tungstenite", &Level::DEBUG));
    assert!(filter.would_enable("tokio_tungstenite", &Level::WARN));
    assert!(!filter.would_enable("h2", &Level::DEBUG));
    assert!(filter.would_enable("h2", &Level::WARN));
    assert!(!filter.would_enable("tower", &Level::DEBUG));
    assert!(filter.would_enable("tower", &Level::WARN));

    // Application trace events should still be retained by default.
    assert!(filter.would_enable("codex_state", &Level::TRACE));
}

#[tokio::test]
async fn sqlite_sink_honors_default_filter() {
    let codex_home =
        std::env::temp_dir().join(format!("codex-state-log-db-filter-{}", Uuid::new_v4()));
    let runtime = StateRuntime::init(codex_home.clone(), "test-provider".to_string())
        .await
        .expect("initialize runtime");
    let layer = start(runtime.clone());

    let guard = tracing_subscriber::registry()
        .with(layer.clone().with_filter(default_filter()))
        .set_default();

    tracing::trace!(target: "opentelemetry_sdk", "dropped-otel");
    tracing::trace!(target: "log", "dropped-log");
    tracing::trace!(target: "hyper_util::client::legacy::pool", "dropped-hyper");
    tracing::trace!(target: "codex_state", "retained-trace");
    tracing::info!(target: "codex_state", "retained-info");

    layer.flush().await;
    drop(guard);

    let logs = runtime
        .query_logs(&crate::LogQuery::default())
        .await
        .expect("query logs after flush");
    assert_eq!(
        logs.iter()
            .map(|row| (
                row.level.as_str(),
                row.target.as_str(),
                row.message.as_deref()
            ))
            .collect::<Vec<_>>(),
        vec![
            ("TRACE", "codex_state", Some("retained-trace")),
            ("INFO", "codex_state", Some("retained-info")),
        ]
    );

    let _ = tokio::fs::remove_dir_all(codex_home).await;
}
