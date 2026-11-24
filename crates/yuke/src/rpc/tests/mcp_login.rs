//! The login of a remote MCP server over the protocol. The MCP server of the tests is its own authorization server. The
//! tests play the browser: they open the page of the login, and they follow the redirect to the listener of yuke.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};

use yuke_http::http::Method;
use yuke_http::http::header::LOCATION;

use super::mcp::mcp_state;
use super::*;

/// Serve a fake MCP server on a loopback port with one thread for each connection, and give its origin. A request to
/// `/mcp` needs the token `good`, which `/token` gives for each code that `/authorize` gave.
fn fake_server() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let served = origin.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let origin = served.clone();
            std::thread::spawn(move || serve(stream, &origin));
        }
    });
    origin
}

/// Answer the requests of one connection.
fn serve(stream: TcpStream, origin: &str) {
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);
    loop {
        let mut start = String::new();
        if !matches!(reader.read_line(&mut start), Ok(1..)) {
            return;
        }
        let (mut length, mut authorization) = (0, String::new());
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let Some((name, value)) = line.trim_end().split_once(':') else {
                break;
            };
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse().unwrap(),
                "authorization" => authorization = value.trim().to_owned(),
                _ => {}
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        let mut parts = start.split(' ');
        let (method, target) = (parts.next().unwrap(), parts.next().unwrap());
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let json = |value: Value| ("200 OK", String::new(), value.to_string());
        let (status, headers, body) = match (method, path) {
            ("POST", "/mcp") if authorization != "Bearer good" => {
                let challenge = format!(
                    "www-authenticate: Bearer \
                     resource_metadata=\"{origin}/.well-known/oauth-protected-resource/mcp\"\r\n"
                );
                ("401 Unauthorized", challenge, String::new())
            }
            ("POST", "/mcp") => mcp_answer(&body),
            ("GET", "/.well-known/oauth-protected-resource/mcp") => json(json!({ "authorization_servers": [origin] })),
            ("GET", "/.well-known/oauth-authorization-server") => json(json!({
                "issuer": origin,
                "authorization_endpoint": format!("{origin}/authorize"),
                "token_endpoint": format!("{origin}/token"),
                "code_challenge_methods_supported": ["S256"],
                "client_id_metadata_document_supported": true,
            })),
            ("GET", "/authorize") => {
                let query = parameters(query);
                let location = format!("{}?code=c&state={}", query["redirect_uri"], query["state"]);
                ("302 Found", format!("location: {location}\r\n"), String::new())
            }
            ("POST", "/token") => json(json!({ "access_token": "good", "refresh_token": "r", "expires_in": 3600 })),
            _ => ("404 Not Found", String::new(), String::new()),
        };
        let answer = format!(
            "HTTP/1.1 {status}\r\n{headers}content-type: application/json\r\nmcp-session-id: s1\r\n\
             content-length: {}\r\n\r\n{body}",
            body.len()
        );
        if writer.write_all(answer.as_bytes()).is_err() {
            return;
        }
    }
}

/// The answer of the MCP endpoint to the JSON-RPC message `body`: a server with no tool.
fn mcp_answer(body: &[u8]) -> (&'static str, String, String) {
    let message: Value = serde_json::from_slice(body).unwrap();
    let result = match message["method"].as_str().unwrap() {
        "initialize" => json!({
            "protocolVersion": "2025-11-25",
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "remote", "version": "1" },
        }),
        "tools/list" => json!({ "tools": [] }),
        _ => return ("202 Accepted", String::new(), String::new()),
    };
    let answer = json!({ "jsonrpc": "2.0", "id": message["id"], "result": result });
    ("200 OK", String::new(), answer.to_string())
}

/// The decoded parameters of `query`.
fn parameters(query: &str) -> HashMap<String, String> {
    let decode = |text: &str| {
        let mut bytes = text.bytes();
        let mut decoded = Vec::new();
        while let Some(byte) = bytes.next() {
            if byte == b'%' {
                let hex: Vec<u8> = bytes.by_ref().take(2).collect();
                decoded.push(u8::from_str_radix(std::str::from_utf8(&hex).unwrap(), 16).unwrap());
            } else {
                decoded.push(byte);
            }
        }
        String::from_utf8(decoded).unwrap()
    };
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(name, value)| (name.to_owned(), decode(value)))
        .collect()
}

/// What the user does on the page `url`: the authorization server redirects the browser to yuke. Gives the redirect.
async fn approve(url: &str) -> String {
    let client = yuke_http::Client::new(yuke_http::http::HeaderValue::from_static("test"));
    let response = client.send(yuke_http::Request::new(Method::GET, url)).await.unwrap();
    assert_eq!(response.status, 302);
    response.headers[LOCATION].to_str().unwrap().to_owned()
}

/// The browser opens the redirect `location`, and the listener of yuke answers with its status.
async fn visit(location: &str) -> u16 {
    let client = yuke_http::Client::new(yuke_http::http::HeaderValue::from_static("test"));
    client
        .send(yuke_http::Request::new(Method::GET, location))
        .await
        .unwrap()
        .status
        .as_u16()
}

/// The remote servers `remote` and `other` of the session need a login, and the local server `sh` runs.
struct Setup {
    client: Client,
    session: Value,
    /// The origin of the MCP server `remote`, which is its authorization server too.
    origin: String,
    /// The data folder, which holds the stored logins.
    data: PathBuf,
    /// The messages that the start and the waits for a state read.
    seen: Vec<Value>,
}

impl Setup {
    /// Start a session with the servers `remote`, `other`, and `sh`, and wait until `remote` needs a login.
    async fn start(name: &str) -> Setup {
        Setup::with_plugin(name, None).await
    }

    /// [`Setup::start`] with the plugin `wizard` of the source `plugin`, when there is one.
    async fn with_plugin(name: &str, plugin: Option<&str>) -> Setup {
        let place = Place::new("rpc", name);
        if let Some(source) = plugin {
            place.plugin("wizard", source);
            std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["wizard"] }"#).unwrap();
        }
        let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/rpc/mcp_server.sh");
        let origin = fake_server();
        let config = json!({ "mcpServers": {
            "remote": { "url": format!("{origin}/mcp") },
            "other": { "url": format!("{}/mcp", fake_server()) },
            "sh": { "command": "sh", "args": [script] },
        } });
        std::fs::create_dir_all(&place.paths.config).unwrap();
        std::fs::write(place.paths.config.join("mcp.json"), config.to_string()).unwrap();
        let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;
        let id = client.request("session/new", settings(&place)).await;
        let seen = client.until(|message| is_response(message, id)).await;
        let session = seen.last().unwrap()["result"]["sessionId"].clone();
        let mut setup = Setup {
            client,
            session,
            origin,
            data: place.paths.data.clone(),
            seen,
        };
        setup.until_state("remote", "needsLogin").await;
        setup
    }

    /// Wait until the server `name` has the state `kind`: its list says so, or its update comes. An update that came
    /// before lies in the messages of the call.
    async fn until_state(&mut self, name: &str, kind: &str) {
        let id = self
            .client
            .request("mcp/list", json!({ "sessionId": self.session }))
            .await;
        let messages = self.client.until(|message| is_response(message, id)).await;
        self.seen.extend(messages.iter().cloned());
        let listed = &messages.last().unwrap()["result"]["servers"];
        let listed = listed
            .as_array()
            .unwrap()
            .iter()
            .any(|server| server["name"] == name && server["state"]["kind"] == kind);
        if !listed && !messages.iter().any(|message| mcp_state(message, name, kind)) {
            let waited = self.client.until(|message| mcp_state(message, name, kind)).await;
            self.seen.extend(waited);
        }
    }

    /// Start the login of `remote`, and answer the result.
    async fn login(&mut self) -> Value {
        self.login_of("remote").await
    }

    /// Start the login of the server `server`, and answer the result.
    async fn login_of(&mut self, server: &str) -> Value {
        self.client
            .call("mcp/login", json!({ "sessionId": self.session, "server": server }))
            .await
            .unwrap()
    }

    /// Send a request, and answer its result and the messages up to its response. A notification that the request
    /// causes can lie in them.
    async fn call(&mut self, method: &str, params: Value) -> (Result<Value, Value>, Vec<Value>) {
        let id = self.client.request(method, params).await;
        let messages = self.client.until(|message| is_response(message, id)).await;
        let response = messages.last().unwrap();
        let result = response.get("result").cloned().ok_or_else(|| response["error"].clone());
        (result, messages)
    }

    /// The params of the `mcp/loginFinished` in `earlier`, else of the next one.
    async fn finished_after(&mut self, earlier: &[Value]) -> Value {
        match earlier.iter().find(|message| message["method"] == "mcp/loginFinished") {
            Some(message) => message["params"].clone(),
            None => self.finished().await,
        }
    }

    /// The params of the next `mcp/loginFinished`.
    async fn finished(&mut self) -> Value {
        let ended = |message: &Value| message["method"] == "mcp/loginFinished";
        self.client.until(ended).await.pop().unwrap()["params"].clone()
    }
}

#[tokio::test(flavor = "local")]
async fn a_login_over_the_loopback_ends_with_a_success_and_connects_the_server() {
    let mut setup = Setup::start("a_login_over_the_loopback").await;

    let started = setup.login().await;
    let page = started["url"].as_str().unwrap().to_owned();
    let location = approve(&page).await;
    let status = visit(&location).await;
    let finished = setup.finished().await;
    setup.until_state("remote", "connected").await;

    assert!(page.starts_with(&format!("{}/authorize?", setup.origin)), "{page}");
    assert_eq!(status, 200);
    assert_eq!(
        finished,
        json!({
            "loginId": started["loginId"],
            "sessionId": setup.session,
            "server": "remote",
            "outcome": { "kind": "succeeded" },
        })
    );
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_login_completes_with_the_pasted_redirect_address() {
    let mut setup = Setup::start("a_login_with_the_pasted_address").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;

    let completed = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": started["loginId"], "redirectUrl": location }),
        )
        .await;
    let finished = setup.finished().await;
    setup.until_state("remote", "connected").await;

    assert_eq!(completed, Ok(json!({})));
    assert_eq!(finished["outcome"], json!({ "kind": "succeeded" }));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_pasted_address_that_is_not_the_redirect_of_the_login_is_an_error_and_the_login_goes_on_to_wait() {
    let mut setup = Setup::start("a_wrong_pasted_address").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;
    let forged = location.replace("state=", "state=forged");

    let refused = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": started["loginId"], "redirectUrl": forged }),
        )
        .await;
    let completed = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": started["loginId"], "redirectUrl": location }),
        )
        .await;
    let finished = setup.finished().await;

    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], json!(-32602));
    assert_eq!(
        refused["message"],
        json!("the state of the redirect is not the state of this login")
    );
    assert_eq!(completed, Ok(json!({})));
    assert_eq!(finished["outcome"], json!({ "kind": "succeeded" }));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_cancelled_login_ends_as_cancelled_and_the_server_still_needs_a_login() {
    let mut setup = Setup::start("a_cancelled_mcp_login").await;
    let started = setup.login().await;

    let cancelled = setup
        .client
        .call("mcp/cancelLogin", json!({ "loginId": started["loginId"] }))
        .await;
    let finished = setup.finished().await;
    let late = setup
        .client
        .call("mcp/cancelLogin", json!({ "loginId": started["loginId"] }))
        .await;

    assert_eq!(cancelled, Ok(json!({})));
    assert_eq!(finished["outcome"], json!({ "kind": "cancelled" }));
    assert_eq!(finished["loginId"], started["loginId"]);
    // The ended login is gone, so its id is unknown.
    assert_eq!(late.unwrap_err()["code"], json!(-32006));
    setup.until_state("remote", "needsLogin").await;
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn an_unknown_login_id_is_the_error_of_a_login_that_is_not_in_progress() {
    let mut setup = Setup::start("an_unknown_mcp_login_id").await;

    let completed = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": 99, "redirectUrl": "http://127.0.0.1/callback" }),
        )
        .await;
    let cancelled = setup.client.call("mcp/cancelLogin", json!({ "loginId": 99 })).await;

    for error in [completed.unwrap_err(), cancelled.unwrap_err()] {
        assert_eq!(error["code"], json!(-32006));
        assert_eq!(error["message"], json!("no login 99 is in progress"));
    }
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_server_that_needs_no_login_or_that_does_not_exist_gives_no_login() {
    let mut setup = Setup::start("a_server_that_needs_no_login").await;
    setup.until_state("sh", "connected").await;

    let running = setup
        .client
        .call("mcp/login", json!({ "sessionId": setup.session, "server": "sh" }))
        .await;
    let missing = setup
        .client
        .call("mcp/login", json!({ "sessionId": setup.session, "server": "nobody" }))
        .await;

    let running = running.unwrap_err();
    assert_eq!(running["code"], json!(-32602));
    assert_eq!(running["message"], json!("the MCP server sh does not need a login"));
    let missing = missing.unwrap_err();
    assert_eq!(missing["code"], json!(-32602));
    assert_eq!(missing["message"], json!("the session has no MCP server nobody"));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_logout_moves_a_connected_remote_server_to_needs_login() {
    let mut setup = Setup::start("an_mcp_logout").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;
    visit(&location).await;
    setup.finished().await;
    setup.until_state("remote", "connected").await;

    let logout = setup
        .client
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "remote" }))
        .await;
    setup.until_state("remote", "needsLogin").await;
    let local = setup
        .client
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "sh" }))
        .await;

    assert_eq!(logout, Ok(json!({})));
    assert_eq!(local.unwrap_err()["code"], json!(-32602));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_second_login_of_the_same_server_ends_the_first_as_cancelled() {
    let mut setup = Setup::start("a_second_mcp_login").await;
    let first = setup.login().await;

    let (second, messages) = setup
        .call("mcp/login", json!({ "sessionId": setup.session, "server": "remote" }))
        .await;
    let second = second.unwrap();
    let cancelled = setup.finished_after(&messages).await;
    let location = approve(second["url"].as_str().unwrap()).await;
    visit(&location).await;
    let finished = setup.finished().await;

    assert_ne!(first["loginId"], second["loginId"]);
    assert_eq!(cancelled["loginId"], first["loginId"]);
    assert_eq!(cancelled["outcome"], json!({ "kind": "cancelled" }));
    assert_eq!(finished["loginId"], second["loginId"]);
    assert_eq!(finished["outcome"], json!({ "kind": "succeeded" }));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn the_close_of_a_session_ends_its_login_as_cancelled() {
    let mut setup = Setup::start("the_close_ends_the_mcp_login").await;
    let started = setup.login().await;

    let (closed, messages) = setup.call("session/close", json!({ "sessionId": setup.session })).await;
    let finished = setup.finished_after(&messages).await;
    let late = setup
        .client
        .call("mcp/cancelLogin", json!({ "loginId": started["loginId"] }))
        .await;

    assert_eq!(closed, Ok(json!({})));
    assert_eq!(finished["loginId"], started["loginId"]);
    assert_eq!(finished["outcome"], json!({ "kind": "cancelled" }));
    assert_eq!(late.unwrap_err()["code"], json!(-32006));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_cancel_after_the_redirect_came_does_not_stop_the_login() {
    let mut setup = Setup::start("a_cancel_after_the_redirect").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;
    // The listener took the code before it answered, so the cancel comes after the redirect.
    assert_eq!(visit(&location).await, 200);

    let cancelled = setup
        .client
        .call("mcp/cancelLogin", json!({ "loginId": started["loginId"] }))
        .await;
    let finished = setup.finished().await;
    setup.until_state("remote", "connected").await;

    assert_eq!(cancelled, Ok(json!({})));
    assert_eq!(finished["outcome"], json!({ "kind": "succeeded" }));
    let stored: Value = serde_json::from_slice(&std::fs::read(setup.data.join("mcp-auth.json")).unwrap()).unwrap();
    assert_eq!(stored.as_object().unwrap().len(), 1);
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_redirect_with_an_error_ends_the_login_as_failed_with_the_error_of_the_authorization_server() {
    let mut setup = Setup::start("a_redirect_with_an_error").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;
    let denied = location.replace("code=c&", "error=access_denied&");

    let completed = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": started["loginId"], "redirectUrl": denied }),
        )
        .await;
    let finished = setup.finished().await;

    assert_eq!(completed, Ok(json!({})));
    assert_eq!(
        finished["outcome"],
        json!({ "kind": "failed", "error": "the authorization server refused the login: access_denied" })
    );
    setup.until_state("remote", "needsLogin").await;
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_logout_ends_the_login_in_progress_of_the_server_and_stores_nothing() {
    let mut setup = Setup::start("a_logout_during_a_login").await;
    let started = setup.login().await;
    let location = approve(started["url"].as_str().unwrap()).await;

    let (logout, messages) = setup
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "remote" }))
        .await;
    let finished = setup.finished_after(&messages).await;
    let late = setup
        .client
        .call(
            "mcp/completeLogin",
            json!({ "loginId": started["loginId"], "redirectUrl": location }),
        )
        .await;

    assert_eq!(logout, Ok(json!({})));
    assert_eq!(finished["loginId"], started["loginId"]);
    assert_eq!(finished["outcome"], json!({ "kind": "cancelled" }));
    assert_eq!(late.unwrap_err()["code"], json!(-32006));
    // The logout wrote the file without a login.
    let stored: Value = serde_json::from_slice(&std::fs::read(setup.data.join("mcp-auth.json")).unwrap()).unwrap();
    assert_eq!(stored, json!({}));
    setup.until_state("remote", "needsLogin").await;
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_logout_of_a_server_that_the_session_lacks_is_an_invalid_request() {
    let mut setup = Setup::start("a_logout_of_a_missing_server").await;

    let missing = setup
        .client
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "nobody" }))
        .await;
    let local = setup
        .client
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "sh" }))
        .await;

    let missing = missing.unwrap_err();
    assert_eq!(missing["code"], json!(-32602));
    assert_eq!(missing["message"], json!("the session has no MCP server nobody"));
    let local = local.unwrap_err();
    assert_eq!(local["code"], json!(-32602));
    assert_eq!(local["message"], json!("sh is not a remote server"));
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_logout_ends_only_the_login_of_its_server() {
    let mut setup = Setup::start("a_logout_ends_only_its_login").await;
    setup.until_state("other", "needsLogin").await;
    let remote = setup.login().await;
    let other = setup.login_of("other").await;
    let location = approve(remote["url"].as_str().unwrap()).await;

    let (logout, messages) = setup
        .call("mcp/logout", json!({ "sessionId": setup.session, "server": "other" }))
        .await;
    let cancelled = setup.finished_after(&messages).await;
    assert_eq!(visit(&location).await, 200);
    let finished = setup.finished().await;

    assert_eq!(logout, Ok(json!({})));
    assert_eq!(
        (cancelled["loginId"].clone(), cancelled["outcome"].clone()),
        (other["loginId"].clone(), json!({ "kind": "cancelled" }))
    );
    assert_eq!(
        (finished["loginId"].clone(), finished["outcome"].clone()),
        (remote["loginId"].clone(), json!({ "kind": "succeeded" }))
    );
    setup.client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_server_that_needs_a_login_gives_a_notice_that_names_mcp() {
    let setup = Setup::start("a_notice_for_a_login").await;

    let notices: Vec<&str> = setup
        .seen
        .iter()
        .filter(|message| message["method"] == "notice")
        .map(|message| message["params"]["text"].as_str().unwrap())
        .collect();

    assert!(
        notices.contains(&"The MCP server remote needs a login: run /mcp"),
        "{notices:?}"
    );
    assert!(
        !notices.iter().any(|text| text.contains("MCP server sh ")),
        "{notices:?}"
    );
}

/// A plugin that logs in to `remote` when it needs a login, waits for the end, and then logs out.
const WIZARD: &str = "import { mcp } from 'yuke:internal/sessions';
    export function apply(ctx) {
      let phase = 'waiting';
      ctx.addListener('session.update', (data) => {
        const update = data.update;
        if (update.kind !== 'mcpServer' || update.name !== 'remote') return;
        const sessionId = data.sessionId;
        if (phase === 'waiting' && update.state.kind === 'needsLogin') {
          phase = 'login';
          void (async () => {
            const login = await mcp.login(sessionId, 'remote');
            ctx.sendClientEvent('started', { url: login.url });
            try { login.complete('http://127.0.0.1:1/callback?code=c&state=wrong'); }
            catch (error) { ctx.sendClientEvent('refused', { text: String(error) }); }
            const outcome = await login.waitForEnd();
            phase = 'connecting';
            ctx.sendClientEvent('ended', outcome);
          })();
        } else if (phase === 'connecting' && update.state.kind === 'connected') {
          phase = 'logout';
          void mcp.logout(sessionId, 'remote').then(() => ctx.sendClientEvent('loggedOut', {}));
        }
      });
    }";

#[tokio::test(flavor = "local")]
async fn a_plugin_logs_in_and_out_of_an_mcp_server_through_the_internal_sessions_module() {
    let mut setup = Setup::with_plugin("a_plugin_mcp_login", Some(WIZARD)).await;
    let is_event = |name: &'static str| {
        move |message: &Value| message["method"] == "extension/event" && message["params"]["event"] == name
    };

    let started = setup.client.until(is_event("started")).await.pop().unwrap();
    let refused = setup.client.until(is_event("refused")).await.pop().unwrap();
    let location = approve(started["params"]["data"]["url"].as_str().unwrap()).await;
    assert_eq!(visit(&location).await, 200);
    let ended = setup.client.until(is_event("ended")).await.pop().unwrap();
    setup.client.until(is_event("loggedOut")).await;
    setup.until_state("remote", "needsLogin").await;

    assert_eq!(
        refused["params"]["data"]["text"],
        "Error: the state of the redirect is not the state of this login"
    );
    assert_eq!(ended["params"]["data"], json!({ "kind": "succeeded" }));
    // The logout of the plugin removed the stored login.
    let stored: Value = serde_json::from_slice(&std::fs::read(setup.data.join("mcp-auth.json")).unwrap()).unwrap();
    assert_eq!(stored, json!({}));
    setup.client.end().await;
}
