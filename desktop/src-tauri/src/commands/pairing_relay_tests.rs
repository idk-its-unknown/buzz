use super::{
    discover_pairing_relay_url, pairing_relay_from_nip11, pairing_relay_override_from_env,
    probe_pairing_relay, resolve_pairing_relay_url, validated_pairing_override, PairingRelay,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn live_nip11_probe_discovers_configured_pairing_relay() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind test NIP-11 server");
    let addr = listener.local_addr().expect("test server address");
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("accept NIP-11 request");
        let mut request = vec![0; 2048];
        let bytes_read = stream.read(&mut request).await.expect("read request");
        let request = String::from_utf8_lossy(&request[..bytes_read]);
        assert!(request.starts_with("GET / HTTP/1.1"));
        assert!(request
            .to_ascii_lowercase()
            .contains("accept: application/nostr+json"));

        let body = r#"{"pairing_relay_url":"ws://127.0.0.1:5000"}"#;
        let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/nostr+json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        stream
            .write_all(response.as_bytes())
            .await
            .expect("write response");
    });

    assert_eq!(
        probe_pairing_relay(&format!("ws://{addr}")).await,
        PairingRelay::Configured("ws://127.0.0.1:5000".to_string())
    );
    server.await.expect("NIP-11 server task");
}

#[test]
fn configured_pairing_relay_takes_precedence_over_legacy_path() {
    let document = serde_json::json!({
        "pairing_relay_url": "wss://pairing.buzz.xyz",
        "supported_nips": [43]
    });

    assert_eq!(
        pairing_relay_from_nip11(&document),
        PairingRelay::Configured("wss://pairing.buzz.xyz".to_string())
    );
}

#[test]
fn invalid_pairing_relay_url_falls_back_to_legacy_path() {
    let document = serde_json::json!({
        "pairing_relay_url": "https://pairing.buzz.xyz",
        "supported_nips": [43]
    });

    assert_eq!(
        pairing_relay_from_nip11(&document),
        PairingRelay::LegacyPath
    );
}

#[test]
fn document_without_pairing_configuration_uses_main_relay() {
    let document = serde_json::json!({ "supported_nips": [1, 11] });

    assert_eq!(pairing_relay_from_nip11(&document), PairingRelay::MainRelay);
}

#[test]
fn configured_pairing_relay_resolves_to_configured_url() {
    let resolved = resolve_pairing_relay_url(
        "wss://flint.communities.buzz.xyz",
        PairingRelay::Configured("wss://pairing.buzz.xyz".to_string()),
    )
    .expect("resolve configured pairing relay");

    assert_eq!(resolved, "wss://pairing.buzz.xyz");
}

#[test]
fn legacy_pairing_relay_appends_pair_path() {
    let resolved = resolve_pairing_relay_url(
        "wss://flint.communities.buzz.xyz/community",
        PairingRelay::LegacyPath,
    )
    .expect("resolve legacy pairing relay");

    assert_eq!(resolved, "wss://flint.communities.buzz.xyz/community/pair");
}

#[test]
fn main_relay_pairing_uses_main_relay_url() {
    let resolved = resolve_pairing_relay_url(
        "wss://sprout-oss.stage.blox.sqprod.co",
        PairingRelay::MainRelay,
    )
    .expect("resolve main pairing relay");

    assert_eq!(resolved, "wss://sprout-oss.stage.blox.sqprod.co");
}

// ── BUZZ_PAIRING_RELAY_URL override ─────────────────────────────────────────

/// Spawn a one-shot NIP-11 server advertising `pairing_relay_url`. Returns
/// the main-relay ws URL to probe and the advertised pairing URL. Used by the
/// fallback tests so a genuinely-executed probe is observable: the advertised
/// URL can only appear in the result if the probe actually ran.
async fn spawn_nip11_stub(advertised: &str) -> (String, String) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind stub NIP-11 server");
    let addr = listener.local_addr().expect("stub server address");
    let body = format!(r#"{{"pairing_relay_url":"{advertised}"}}"#);
    tokio::spawn(async move {
        if let Ok((mut stream, _)) = listener.accept().await {
            let mut request = vec![0; 2048];
            let _ = stream.read(&mut request).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/nostr+json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes()).await;
        }
    });
    (format!("ws://{addr}"), advertised.to_string())
}

#[test]
fn override_accepts_and_normalizes_ws_and_wss_urls() {
    // The WHATWG serialization is returned (empty path becomes "/"), so the
    // dialed URL is exactly the validated one.
    assert_eq!(
        validated_pairing_override(Some("ws://203.0.113.7:3001".into())),
        Ok(Some("ws://203.0.113.7:3001/".to_string()))
    );
    assert_eq!(
        validated_pairing_override(Some("wss://pairing.example.com".into())),
        Ok(Some("wss://pairing.example.com/".to_string()))
    );
}

#[test]
fn override_trims_surrounding_whitespace() {
    assert_eq!(
        validated_pairing_override(Some("  ws://203.0.113.7:3001  ".into())),
        Ok(Some("ws://203.0.113.7:3001/".to_string()))
    );
}

#[test]
fn override_normalizes_whatwg_tolerated_whitespace() {
    // url::Url strips interior tab/CR/LF during parsing; the returned
    // serialization must be the cleaned form, or the raw string would pass
    // validation here and then be rejected by http::Uri at dial time.
    assert_eq!(
        validated_pairing_override(Some("ws://203.0.113.7:3\n001".into())),
        Ok(Some("ws://203.0.113.7:3001/".to_string()))
    );
}

#[test]
fn unset_or_blank_override_is_absent() {
    assert_eq!(validated_pairing_override(None), Ok(None));
    assert_eq!(validated_pairing_override(Some(String::new())), Ok(None));
    assert_eq!(validated_pairing_override(Some("   ".into())), Ok(None));
}

#[test]
fn set_but_invalid_override_is_a_loud_error() {
    // The operator asked for an override and did not get it — silent fallback
    // would route pairing to the (broken) discovered path with no signal.
    for bad in [
        "http://pairing.example.com", // wrong scheme
        "not a url",
        "ws://", // hostless
    ] {
        let result = validated_pairing_override(Some(bad.into()));
        let err = result.expect_err(&format!("{bad:?} must be rejected"));
        assert!(
            err.contains("BUZZ_PAIRING_RELAY_URL"),
            "error must name the env var so the operator can find it: {err}"
        );
    }
}

#[test]
fn env_reader_is_wired_to_the_documented_name() {
    // Pins the const to the documented env-var name end to end. No other test
    // touches this variable, so there is no parallel-test race on it — but
    // save/restore any ambient value anyway (the developer machine may have a
    // real override set), matching this codebase's env-test pattern.
    let previous = std::env::var_os("BUZZ_PAIRING_RELAY_URL");

    std::env::set_var("BUZZ_PAIRING_RELAY_URL", "ws://203.0.113.7:3001");
    assert_eq!(
        pairing_relay_override_from_env(),
        Some("ws://203.0.113.7:3001".to_string())
    );
    std::env::remove_var("BUZZ_PAIRING_RELAY_URL");
    assert_eq!(pairing_relay_override_from_env(), None);

    if let Some(value) = previous {
        std::env::set_var("BUZZ_PAIRING_RELAY_URL", value);
    }
}

#[tokio::test]
async fn override_wins_without_probing_the_main_relay() {
    // The "main relay" here is a listener that records any connection attempt.
    // A valid override must resolve without ever dialing NIP-11.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind probe-canary listener");
    let addr = listener.local_addr().expect("canary address");
    let contacted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = std::sync::Arc::clone(&contacted);
    tokio::spawn(async move {
        if listener.accept().await.is_ok() {
            flag.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    });

    let resolved = discover_pairing_relay_url(
        Some("ws://203.0.113.7:3001".to_string()),
        &format!("ws://{addr}"),
    )
    .await
    .expect("override must resolve");

    assert_eq!(resolved, "ws://203.0.113.7:3001/");
    // Give a hypothetical concurrently-launched probe a beat to land before
    // asserting it never happened.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(
        !contacted.load(std::sync::atomic::Ordering::SeqCst),
        "override must short-circuit the NIP-11 probe"
    );
}

#[tokio::test]
async fn set_but_invalid_override_errors_without_probing() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind probe-canary listener");
    let addr = listener.local_addr().expect("canary address");
    let contacted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = std::sync::Arc::clone(&contacted);
    tokio::spawn(async move {
        if listener.accept().await.is_ok() {
            flag.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    });

    let result = discover_pairing_relay_url(
        Some("http://pairing.example.com".to_string()),
        &format!("ws://{addr}"),
    )
    .await;

    let err = result.expect_err("set-but-invalid override must error");
    assert!(err.contains("BUZZ_PAIRING_RELAY_URL"));
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(
        !contacted.load(std::sync::atomic::Ordering::SeqCst),
        "invalid override must fail before any probe"
    );
}

#[tokio::test]
async fn no_override_falls_back_to_probe() {
    // The stub advertises a pairing URL; seeing it in the result proves the
    // NIP-11 probe genuinely ran (a skipped probe could never produce it).
    let (main_ws, advertised) = spawn_nip11_stub("ws://127.0.0.1:5001").await;
    let resolved = discover_pairing_relay_url(None, &main_ws)
        .await
        .expect("fallback must resolve");
    assert_eq!(resolved, advertised);
}

#[tokio::test]
async fn blank_override_falls_back_to_probe() {
    let (main_ws, advertised) = spawn_nip11_stub("ws://127.0.0.1:5002").await;
    let resolved = discover_pairing_relay_url(Some("   ".to_string()), &main_ws)
        .await
        .expect("fallback must resolve");
    assert_eq!(resolved, advertised);
}
