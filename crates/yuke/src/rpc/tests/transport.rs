//! The transports: stdio, the socket and its clients, and the writer of the output.

use super::*;

#[tokio::test]
async fn a_client_that_stops_reading_cannot_hold_the_server_after_its_input_ends() {
    let place = Place::new(
        "rpc",
        "a_client_that_stops_reading_cannot_hold_the_server_after_its_input_ends",
    );
    let (mut input, server_input) = tokio::io::duplex(1 << 16);
    // The client keeps its end of the output and never reads it, so the small pipe fills.
    let (server_output, _unread) = tokio::io::duplex(1 << 10);
    let machine = place.machine(Box::new(with_key), Box::new(ScriptedTransport::default()));
    let server = tokio::spawn(serve(
        machine,
        Duration::from_millis(100),
        Clients::One(Stream::new(server_input, server_output)),
        std::future::pending(),
    ));
    let request = json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" }
    } });
    for _ in 0..200 {
        input.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    }

    drop(input);
    let ended = tokio::time::timeout(Duration::from_secs(5), server).await;

    ended.expect("the server still waits for the client").unwrap().unwrap();
}

#[tokio::test]
async fn a_server_that_ends_without_its_shutdown_still_stops_its_turns() {
    let place = Place::new("rpc", "a_server_that_ends_without_its_shutdown_still_stops_its_turns");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    client.server.as_ref().unwrap().abort();
    // Each running task holds the output open, so its end shows that the stalled turn stopped.
    let drained = tokio::time::timeout(Duration::from_secs(5), async {
        while client.output.next_line().await.is_ok_and(|line| line.is_some()) {}
    })
    .await;

    assert!(drained.is_ok(), "a turn still runs after the server ended");
}

#[tokio::test]
async fn a_turn_outlives_its_socket_client_and_the_next_client_takes_it_over() {
    let place = Place::new("rpc", "turn_outlives_client");
    let listening = Listening::start(&place, Box::new(Stalled));
    let mut first = listening.client().await;
    let first_instance = first.initialize().await["instanceId"].clone();
    let session = first.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    first.request("session/input", input_params(&session, "hi")).await;
    first
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    drop(first);
    let mut second = listening.client().await;
    let second_instance = second.initialize().await["instanceId"].clone();
    let loaded = second.load(&session, json!({})).await;
    second.notify("session/cancel", json!({ "sessionId": session })).await;
    let ended = second.until(is_idle).await;

    // A missing id would pass the equality as null.
    assert!(first_instance.is_string(), "{first_instance}");
    assert_eq!(second_instance, first_instance);
    assert_eq!(loaded.state, "running");
    assert!(
        ended
            .iter()
            .any(|message| message["params"]["update"]["sessionUpdate"] == "commit"),
        "{ended:?}"
    );
    listening.stop().await;
}

#[tokio::test]
async fn a_new_socket_client_replaces_the_active_client() {
    let place = Place::new("rpc", "new_client_replaces");
    let listening = Listening::start(&place, Box::new(ScriptedTransport::default()));
    let mut first = listening.client().await;
    first.initialize().await;

    let mut second = listening.client().await;
    second.initialize().await;
    let created = second.call("session/new", settings(&place)).await;

    first.expect_closed().await;
    assert!(created.is_ok(), "{created:?}");
    listening.stop().await;
}

#[tokio::test]
async fn a_socket_server_outlives_its_clients_and_its_shutdown_ends_the_turns_then_the_connection() {
    let place = Place::new("rpc", "socket_shutdown");
    let listening = Listening::start(&place, Box::new(Stalled));
    let mut first = listening.client().await;
    first.initialize().await;
    first.end().await;
    let mut second = listening.client().await;
    second.initialize().await;
    let session = second.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    second.request("session/input", input_params(&session, "hi")).await;
    second
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;
    let path = listening.path.clone();

    listening.stop().await;
    let ended = second.until(is_idle).await;

    assert!(
        ended
            .iter()
            .any(|message| message["params"]["update"]["sessionUpdate"] == "commit"),
        "{ended:?}"
    );
    second.expect_closed().await;
    assert!(!path.exists());
}

#[tokio::test]
async fn a_bind_replaces_a_stale_socket_and_refuses_a_held_lock_and_a_file_that_is_no_socket() {
    let stale = socket_path();
    // The standard listener leaves its socket file when it drops, as a server that ends without its shutdown does.
    drop(std::os::unix::net::UnixListener::bind(&stale).unwrap());
    let regular = socket_path();
    std::fs::write(&regular, "kept").unwrap();

    let replaced = Socket::bind(&stale);
    let held = Socket::bind(&stale);
    let not_socket = Socket::bind(&regular);

    assert!(replaced.is_ok(), "{:?}", replaced.as_ref().err());
    let mode = std::fs::metadata(&stale).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    assert!(held.err().unwrap().ends_with("another server listens on the socket"));
    assert!(not_socket.err().unwrap().ends_with("the file is no socket"));
    assert_eq!(std::fs::read_to_string(&regular).unwrap(), "kept");
    drop(replaced);
    assert!(!stale.exists());
    // The drop frees the lock, so the next server binds.
    assert!(Socket::bind(&stale).is_ok());
    for file in [
        stale.with_added_extension("lock"),
        regular.with_added_extension("lock"),
        regular,
    ] {
        std::fs::remove_file(file).unwrap();
    }
}

#[tokio::test]
async fn a_refused_bind_opens_no_connection_to_the_running_server() {
    let path = socket_path();
    let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    let lock = File::create(path.with_added_extension("lock")).unwrap();
    lock.try_lock().unwrap();

    let refused = Socket::bind(&path);

    assert!(refused.is_err());
    // A connection would replace the active client of the server.
    assert_eq!(listener.accept().unwrap_err().kind(), io::ErrorKind::WouldBlock);
    for file in [path.with_added_extension("lock"), path] {
        std::fs::remove_file(file).unwrap();
    }
}

#[tokio::test]
async fn connect_bridges_the_socket_until_the_end_of_its_input() {
    let place = Place::new("rpc", "connect_bridges");
    let listening = Listening::start(&place, Box::new(ScriptedTransport::default()));
    let (input, bridge_input) = tokio::io::duplex(1 << 16);
    let (bridge_output, output) = tokio::io::duplex(1 << 16);
    let path = listening.path.clone();
    let bridge = tokio::spawn(async move { connect(&path, bridge_input, bridge_output).await });
    let mut client = Client::new(input, output);

    let initialized = client.initialize().await;
    // The end of the input ends the connection, and so the bridge.
    client.end().await;
    let bridged = tokio::time::timeout(Duration::from_secs(10), bridge).await;

    assert_eq!(initialized["agentInfo"]["name"], "yuke");
    bridged.expect("the bridge did not end").unwrap().unwrap();
    listening.stop().await;
}

#[tokio::test]
async fn a_shutdown_ends_a_stdio_server_while_its_input_stays_open() {
    let place = Place::new("rpc", "stdio_shutdown");
    let (_input, server_input) = tokio::io::duplex(1 << 16);
    let (server_output, _output) = tokio::io::duplex(1 << 16);
    let shutdown = CancellationToken::new();
    let server = tokio::spawn(serve(
        place.machine(Box::new(with_key), Box::new(ScriptedTransport::default())),
        Duration::from_secs(10),
        Clients::One(Stream::new(server_input, server_output)),
        shutdown.clone().cancelled_owned(),
    ));

    shutdown.cancel();
    let served = tokio::time::timeout(Duration::from_secs(10), server).await;

    served.expect("the server did not end").unwrap().unwrap();
}

/// An output that keeps its bytes and counts its flushes.
struct CountedOutput(Arc<Mutex<(Vec<u8>, usize)>>);

impl AsyncWrite for CountedOutput {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        self.0.lock().unwrap().0.extend_from_slice(bytes);
        std::task::Poll::Ready(Ok(bytes.len()))
    }

    fn poll_flush(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<io::Result<()>> {
        self.0.lock().unwrap().1 += 1;
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[tokio::test]
async fn the_writer_writes_a_burst_of_lines_in_order_with_one_flush() {
    let counted = Arc::new(Mutex::new((Vec::new(), 0)));
    let (writer, written) = Writer::start(CountedOutput(Arc::clone(&counted)));

    // The writer task runs only at the next await, so the three lines wait in the queue together.
    for number in 1..=3 {
        writer.send(&json!({ "n": number }));
    }
    drop(writer);
    written.await.unwrap();

    let (bytes, flushes) = &*counted.lock().unwrap();
    assert_eq!(bytes, b"{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n");
    assert_eq!(*flushes, 1);
}

#[tokio::test]
async fn a_burst_past_the_batch_size_writes_in_two_batches_and_loses_no_line() {
    let counted = Arc::new(Mutex::new((Vec::new(), 0)));
    let (writer, written) = Writer::start(CountedOutput(Arc::clone(&counted)));
    let texts: Vec<String> = ["a", "b", "c"].iter().map(|letter| letter.repeat(40_000)).collect();

    // Two lines pass 64 KiB, so the first write stops after them, and the third line goes in a second write.
    for text in &texts {
        writer.send(text);
    }
    drop(writer);
    written.await.unwrap();

    let (bytes, flushes) = &*counted.lock().unwrap();
    let expected = format!("\"{}\"\n\"{}\"\n\"{}\"\n", texts[0], texts[1], texts[2]);
    assert_eq!(bytes, expected.as_bytes());
    assert_eq!(*flushes, 2);
}
