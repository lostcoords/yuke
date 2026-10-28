//! Background jobs: their updates, their stop, and their end with a folder change or a close.

use super::*;

#[tokio::test]
async fn a_background_job_tells_its_start_and_end_then_sends_an_input_that_the_model_reads() {
    let place = Place::new("rpc", "background_job_end");
    let arguments = json!({ "command": "exit 3", "background": true }).to_string();
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "exec", &arguments)]),
        text_reply("started"),
        text_reply("noted"),
    ]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client
        .request("session/input", input_params(&session, "start a job"))
        .await;

    // The job can end during the first turn or after it. Its input then joins that turn, or it starts a new one. The
    // wait ends at the first idle state after a commit that consumed the input.
    let mut messages = Vec::new();
    let mut job_input = None;
    let mut consumed = false;
    loop {
        let message = client.next().await;
        let update = &message["params"]["update"];
        if update["sessionUpdate"] == "input_accepted" && update["input"]["source"]["name"] == "host:jobs" {
            job_input = Some((messages.len(), update["inputId"].clone(), update["input"].clone()));
        } else if let Some((_, id, _)) = &job_input
            && update["sessionUpdate"] == "commit"
            && update["consumed"]
                .as_array()
                .unwrap()
                .iter()
                .any(|input| &input["id"] == id)
        {
            consumed = true;
        } else if consumed && is_idle(&message) {
            break;
        }
        messages.push(message);
    }

    let (input_index, _, job_input) = job_input.unwrap();
    let jobs: Vec<&Value> = messages[..input_index]
        .iter()
        .filter(|message| message["params"]["update"]["sessionUpdate"] == "job")
        .map(|message| &message["params"]["update"]["job"])
        .collect();
    // The start and the end update come before the end input.
    assert_eq!(jobs.len(), 2, "{jobs:?}");
    assert_eq!(jobs[0]["state"], "running");
    assert_eq!(jobs[0]["command"], "exit 3");
    // The end update holds the whole job.
    assert_eq!(
        (&jobs[1]["id"], &jobs[1]["command"], &jobs[1]["log"]),
        (&jobs[0]["id"], &jobs[0]["command"], &jobs[0]["log"])
    );
    assert_eq!(
        (&jobs[1]["state"], &jobs[1]["exitCode"], &jobs[1]["stopped"]),
        (&json!("ended"), &json!(3), &json!(false))
    );
    let shown = job_input["content"][0]["user_text"].as_str().unwrap();
    assert!(shown.starts_with("job-") && shown.ends_with(" ended"), "{shown}");
    let job = shown.trim_end_matches(" ended");
    let model_text = job_input["modelContent"][0]["user_text"].as_str().unwrap();
    assert!(
        model_text.starts_with(&format!(r#"<system_notification plugin="host:jobs">{job} exited 3."#)),
        "{model_text}"
    );
    assert!(model_text.ends_with("</system_notification>"), "{model_text}");
    // The model reads the whole end text, as JSON in the body of a request.
    let quoted = serde_json::to_string(model_text).unwrap();
    let text = &quoted[1..quoted.len() - 1];
    assert!(
        transport.requests().iter().any(|request| request.contains(text)),
        "{text}"
    );
    client.end().await;
}

/// A client with a session whose first turn started a background job, the id of that session, and the transport. The
/// job writes its process id to the file `pid` of the place in one rename, so a reader never sees a part of it. Then
/// it sleeps far longer than any test runs.
async fn session_with_a_job(place: &Place) -> (Client, Value, ScriptedTransport) {
    let pid = place.work.join("pid");
    let command = format!(
        "echo $$ > {pid}.part && mv {pid}.part {pid} && exec sleep 3600",
        pid = pid.display()
    );
    let arguments = json!({ "command": command, "background": true }).to_string();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "exec", &arguments)]), text_reply("started")]);
    let mut client = Client::initialized(place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(place)).await.unwrap()["sessionId"].clone();
    client
        .request("session/input", input_params(&session, "start a job"))
        .await;
    client.until(is_idle).await;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !place.work.join("pid").exists() {
        assert!(std::time::Instant::now() < deadline, "the job did not start");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    (client, session, transport)
}

/// Whether the job of [`session_with_a_job`] in `place` still runs.
fn job_runs(place: &Place) -> bool {
    let pid: u32 = std::fs::read_to_string(place.work.join("pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

/// The id of the one running job of `session`: the job of [`session_with_a_job`]. Its log file exists.
async fn the_job(client: &mut Client, session: &Value) -> Value {
    let listed = client.call("job/list", json!({ "sessionId": session })).await.unwrap();
    let jobs = listed["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 1, "{listed}");
    assert!(
        jobs[0]["command"].as_str().unwrap().ends_with(" && exec sleep 3600"),
        "{listed}"
    );
    let id = jobs[0]["id"].as_str().unwrap();
    let log = PathBuf::from(jobs[0]["log"].as_str().unwrap());
    assert_eq!(log.file_name().unwrap(), format!("{id}.log").as_str(), "{listed}");
    assert!(log.exists(), "{listed}");
    jobs[0]["id"].clone()
}

#[tokio::test]
async fn after_a_folder_change_the_tools_work_in_the_new_folder_and_stop_the_old_jobs() {
    let place = Place::new(
        "rpc",
        "after_a_folder_change_the_tools_work_in_the_new_folder_and_stop_the_old_jobs",
    );
    let (mut client, session, transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;
    let other = place.work.join("other");
    std::fs::create_dir(&other).unwrap();
    let mut settings = settings(&place);
    settings["sessionId"] = session.clone();
    settings["cwd"] = json!(other);
    client.call("session/set_settings", settings).await.unwrap();
    transport.push(tool_reply(&[("c2", "stop", &json!({ "id": job }).to_string())]));
    transport.push(tool_reply(&[("c3", "exec", r#"{"command":"pwd"}"#)]));
    transport.push(text_reply("stopped"));

    client
        .request("session/input", input_params(&session, "stop the job"))
        .await;
    client.until(is_idle).await;
    let after = client.call("job/list", json!({ "sessionId": session })).await;

    assert_eq!(after.unwrap(), json!({ "jobs": [] }));
    assert!(!job_runs(&place));
    let last_request = transport.requests().pop().unwrap();
    assert!(
        last_request.contains(&format!("{}\\n", other.display())),
        "{last_request}"
    );
    client.end().await;
}

#[tokio::test]
async fn a_close_needs_stop_jobs_while_jobs_run_and_then_ends_them() {
    let place = Place::new("rpc", "a_close_needs_stop_jobs_while_jobs_run_and_then_ends_them");
    let (mut client, session, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;

    let refused = client
        .call("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let runs_after_refusal = job_runs(&place);
    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": true }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;
    let loaded = client.load(&session, json!({})).await;

    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], json!(ResponseError::INVALID_REQUEST));
    assert!(
        refused["message"].as_str().unwrap().contains(job.as_str().unwrap()),
        "{refused}"
    );
    assert!(runs_after_refusal);
    let labels: Vec<String> = closed.iter().filter_map(label).collect();
    assert_eq!(labels, ["job", "response"]);
    let ended = &closed[0]["params"]["update"]["job"];
    assert_eq!(
        (&ended["id"], &ended["state"], &ended["stopped"]),
        (&job, &json!("ended"), &json!(true))
    );
    assert_eq!(closed[1]["result"], json!({}));
    // The close waits for the end of the job, so its process is gone.
    assert!(!job_runs(&place));
    assert_eq!((loaded.state, loaded.jobs), (json!("idle"), Vec::new()));
    client.end().await;
}

#[tokio::test]
async fn job_stop_waits_for_the_end_and_its_job_update_comes_first() {
    let place = Place::new("rpc", "job_stop_waits_for_the_end_and_its_job_update_comes_first");
    let (mut client, session, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;

    let loaded = client.load(&session, json!({})).await;
    let id = client
        .request("job/stop", json!({ "sessionId": session, "jobId": job }))
        .await;
    let stopped = client.until(|message| message["id"] == json!(id)).await;
    let again = client
        .call("job/stop", json!({ "sessionId": session, "jobId": job }))
        .await;
    // The close waits for the job task, so an end input of the stopped job would come before its response.
    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;

    assert_eq!(loaded.jobs.len(), 1);
    let loaded_job = &loaded.jobs[0];
    assert_eq!((&loaded_job["id"], &loaded_job["state"]), (&job, &json!("running")));
    // The snapshot holds the whole job.
    assert!(
        loaded_job["command"].as_str().unwrap().ends_with(" && exec sleep 3600"),
        "{loaded_job}"
    );
    let log = PathBuf::from(loaded_job["log"].as_str().unwrap());
    assert_eq!(
        log.file_name().unwrap(),
        format!("{}.log", job.as_str().unwrap()).as_str()
    );
    // The stop waits, so the process is gone, and the end update comes before the answer.
    assert!(!job_runs(&place));
    assert_eq!(
        stopped.iter().filter_map(label).collect::<Vec<_>>(),
        ["job", "response"]
    );
    assert_eq!(stopped[1]["result"], json!({}));
    let ended = &stopped[0]["params"]["update"]["job"];
    assert_eq!(ended["id"], job);
    assert_eq!(ended["state"], "ended");
    assert_eq!(ended["stopped"], true);
    // The job is `exec sleep`, so SIGTERM ends it.
    assert_eq!(ended["signal"], 15, "{ended}");
    assert_eq!(again.unwrap_err()["code"], json!(ResponseError::JOB_NOT_FOUND));
    assert_eq!(closed.iter().filter_map(label).collect::<Vec<_>>(), ["response"]);
    assert_eq!(closed[0]["result"], json!({}));
    client.end().await;
}

#[tokio::test]
async fn a_session_cannot_stop_the_job_of_another_session() {
    let place = Place::new("rpc", "a_session_cannot_stop_the_job_of_another_session");
    let (mut client, owner, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &owner).await;
    let other = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let refused = client
        .call("job/stop", json!({ "sessionId": other, "jobId": job }))
        .await;
    let listed = client.call("job/list", json!({ "sessionId": other })).await;

    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::JOB_NOT_FOUND));
    assert_eq!(listed.unwrap(), json!({ "jobs": [] }));
    assert!(job_runs(&place));
    assert_eq!(the_job(&mut client, &owner).await, job);
    client.end().await;
}

#[tokio::test]
async fn a_job_of_an_open_session_still_runs_after_a_reload() {
    let place = Place::new("rpc", "reload_job");
    let (mut client, session, _transport) = session_with_a_job(&place).await;

    let reloaded = client.call("profile/reload", json!({})).await;

    assert_eq!(reloaded, Ok(json!({})));
    assert!(job_runs(&place));
    the_job(&mut client, &session).await;
    client
        .call("session/close", json!({ "sessionId": session, "stopJobs": true }))
        .await
        .unwrap();
    client.end().await;
}
