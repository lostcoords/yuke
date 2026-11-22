use yuke_http::testing::{Server, listen};

use super::*;

/// Answer one release check as `server` says, and give its result and the path that the check asked for.
async fn check_with(server: Server, current: &str, channel: Channel) -> (Result<Found, String>, String) {
    let (port, seen) = listen(server).await;
    let origin = format!("http://127.0.0.1:{port}");
    let hosts = Hosts {
        pages: origin.clone(),
        api: origin,
    };
    let client = Client::new(header::HeaderValue::from_static("yuke-test"));
    let found = check(&client, &hosts, current, channel).await;
    (found, seen.await.unwrap().target)
}

fn newest_stable(location: &'static str) -> Server {
    Server {
        status: 302,
        headers: vec![("location", location)],
        ..Server::default()
    }
}

fn nightly(commit: &str) -> Server {
    Server {
        status: 200,
        body: format!(r#"{{"tag_name":"nightly","target_commitish":"{commit}"}}"#).into_bytes(),
        ..Server::default()
    }
}

#[test]
fn a_version_names_its_channel() {
    assert_eq!(channel_of("0.1.1"), Some(Channel::Stable));
    assert_eq!(channel_of("1.2.0-rc.1"), Some(Channel::Stable));
    assert_eq!(
        channel_of("0.2.0-nightly.20261122+62af33395709"),
        Some(Channel::Nightly)
    );
    assert_eq!(channel_of("0.2.0-dev"), None);
    assert_eq!(channel_of("0.1.1+dirty"), None);
    assert_eq!(channel_of("0.2.0-nightly.20261122+62af33395709.dirty"), None);
}

#[test]
fn a_version_argument_drops_its_v_and_holds_only_the_characters_of_a_tag() {
    assert_eq!(version_argument("v0.1.0"), Ok("0.1.0".to_owned()));
    assert_eq!(version_argument("1.2.0-rc.1"), Ok("1.2.0-rc.1".to_owned()));
    for value in ["", "v", "latest", "0.1.0/../x", "0.1.0 x"] {
        assert!(version_argument(value).is_err(), "{value}");
    }
}

#[test]
fn a_release_is_older_by_its_numbers_and_then_by_a_prerelease_suffix() {
    assert!(is_older("0.1.0", "0.1.1"));
    assert!(is_older("0.1.1", "0.2.0-nightly.20261122+62af33395709"));
    assert!(is_older("0.2.0-rc.1", "0.2.0"));
    assert!(!is_older("0.2.0", "0.2.0-nightly.20261122+62af33395709"));
    assert!(!is_older("0.10.0", "0.9.0"));
    assert!(!is_older("0.1.1", "0.1.1"));
}

#[test]
fn only_the_program_at_the_path_of_the_installer_counts_as_installed() {
    let home = yuke_testing::folder("update", "installed");
    let installed = home.join(".local/bin/yuke");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    assert!(!is_installed(&installed, &home), "a missing program");
    std::fs::write(&installed, "").unwrap();
    let link = home.join("link");
    std::os::unix::fs::symlink(&installed, &link).unwrap();
    let other = home.join("yuke");
    std::fs::write(&other, "").unwrap();

    assert!(is_installed(&installed, &home));
    assert!(is_installed(&link, &home));
    assert!(!is_installed(&other, &home));
}

#[tokio::test(flavor = "local")]
async fn a_release_is_current_when_the_newest_stable_release_has_its_version() {
    let location = "https://github.com/lostcoords/yuke/releases/tag/v0.1.1";

    let (found, path) = check_with(newest_stable(location), "0.1.1", Channel::Stable).await;
    let (newer, _) = check_with(newest_stable(location), "0.1.0", Channel::Stable).await;

    assert_eq!(found, Ok(Found::Current));
    assert_eq!(path, "/lostcoords/yuke/releases/latest");
    assert_eq!(
        newer,
        Ok(Found::Other {
            version: Some("0.1.1".to_owned())
        })
    );
}

#[tokio::test(flavor = "local")]
async fn a_stable_check_with_no_redirect_to_a_tag_fails() {
    let location = "https://github.com/lostcoords/yuke/releases";
    let (found, _) = check_with(newest_stable(location), "0.1.0", Channel::Stable).await;
    assert_eq!(
        found,
        Err("GitHub answered the release check with 302 Found".to_owned())
    );
}

#[tokio::test(flavor = "local")]
async fn a_nightly_is_current_when_the_nightly_release_has_its_commit() {
    let current = "0.2.0-nightly.20261122+62af33395709";
    let built = "62af33395709e2bdfe601533933363739ff8d464";

    let (found, path) = check_with(nightly(built), current, Channel::Nightly).await;
    let (newer, _) = check_with(
        nightly("1e39c85a0000000000000000000000000000000"),
        current,
        Channel::Nightly,
    )
    .await;
    let (from_stable, _) = check_with(nightly(built), "0.1.1", Channel::Nightly).await;

    assert_eq!(found, Ok(Found::Current));
    assert_eq!(path, "/repos/lostcoords/yuke/releases/tags/nightly");
    assert_eq!(newer, Ok(Found::Other { version: None }));
    assert_eq!(from_stable, Ok(Found::Other { version: None }));
}

#[tokio::test(flavor = "local")]
async fn a_missing_nightly_release_asks_for_a_new_try() {
    let missing = Server {
        status: 404,
        ..Server::default()
    };
    let (found, _) = check_with(missing, "0.1.1", Channel::Nightly).await;
    assert!(found.unwrap_err().contains("try again in a few minutes"));
}
