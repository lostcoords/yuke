//! `yuke update`: install a release of yuke with the installer of yuke.sh. The installer owns each install step, so
//! this module only finds the release, compares it with the running build, and runs the installer.

use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use serde::Deserialize;
use yuke_http::http::{Method, StatusCode, header};
use yuke_http::{Client, ClientOptions, Request, Response};

use crate::app::{progress, say, warn};

/// The repository of the releases, as `OWNER/NAME`.
const REPOSITORY: &str = "lostcoords/yuke";

/// The installer that the install guide names.
const INSTALLER: &str = "https://yuke.sh/install.sh";

/// The longest time of one request, up to the end of its body.
const REQUEST_LIMIT: Duration = Duration::from_secs(60);

/// A release channel of yuke.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum Channel {
    /// The newest tagged release.
    Stable,
    /// The newest build of the main branch.
    Nightly,
}

impl Channel {
    /// The value of `YUKE_CHANNEL` for the installer.
    fn name(self) -> &'static str {
        match self {
            Channel::Stable => "stable",
            Channel::Nightly => "nightly",
        }
    }
}

/// The channel of a build of the version `version`, by the rules of `tools/package.py`. A build from source has none.
fn channel_of(version: &str) -> Option<Channel> {
    if version.contains("-dev") || version.contains("dirty") {
        None
    } else if version.contains("-nightly.") {
        Some(Channel::Nightly)
    } else {
        Some(Channel::Stable)
    }
}

/// The version of a `VERSION` argument, `0.1.0` or `v0.1.0`, with no `v`. It goes into a URL, so it holds only the
/// characters of a release tag.
pub(crate) fn version_argument(value: &str) -> Result<String, String> {
    let version = value.strip_prefix('v').unwrap_or(value);
    let valid = version.starts_with(|character: char| character.is_ascii_digit())
        && (version.chars()).all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-'));
    if valid {
        Ok(version.to_owned())
    } else {
        Err("use a version such as 0.1.0".to_owned())
    }
}

/// Whether the release `version` is older than the build `current`: its numbers are lower, or they are equal and only
/// `version` has a prerelease suffix such as `-rc.1`.
fn is_older(version: &str, current: &str) -> bool {
    // The numbers, then `true` for a release with no suffix, so a prerelease sorts before its release.
    let key = |version: &str| {
        let core = version.split_once('+').map_or(version, |(core, _)| core);
        let (numbers, suffix) = core
            .split_once('-')
            .map_or((core, None), |(numbers, suffix)| (numbers, Some(suffix)));
        let numbers: Vec<u64> = numbers.split('.').map(|number| number.parse().unwrap_or(0)).collect();
        (numbers, suffix.is_none())
    };
    key(version) < key(current)
}

/// Whether `program` is the yuke that the installer writes in the home folder `home`.
fn is_installed(program: &Path, home: &Path) -> bool {
    // On macOS, the path of the running program can be a symbolic link.
    match (program.canonicalize(), home.join(".local/bin/yuke").canonicalize()) {
        (Ok(program), Ok(installed)) => program == installed,
        _ => false,
    }
}

/// The origins of the release pages and of the GitHub API.
#[derive(Debug)]
struct Hosts {
    pages: String,
    api: String,
}

/// What the release check found.
#[derive(Debug, PartialEq, Eq)]
enum Found {
    /// The running build is the release.
    Current,
    /// Another release. A nightly has no `version` before its install.
    Other { version: Option<String> },
}

/// The part of a GitHub release that the nightly check reads.
#[derive(Debug, Deserialize)]
struct NightlyRelease {
    /// The full commit of the build.
    target_commitish: String,
}

/// Find the newest release of `channel`, and compare it with the build of the version `current`.
async fn check(client: &Client, hosts: &Hosts, current: &str, channel: Channel) -> Result<Found, String> {
    match channel {
        Channel::Stable => {
            let response = get(client, format!("{}/{REPOSITORY}/releases/latest", hosts.pages)).await?;
            // GitHub redirects to the page of the tag of the newest release.
            let version = (response.headers.get(header::LOCATION))
                .and_then(|location| location.to_str().ok())
                .and_then(|location| location.rsplit_once("/tag/v"))
                .map(|(_, version)| version)
                .ok_or_else(|| format!("GitHub answered the release check with {}", response.status))?;
            Ok(if version == current {
                Found::Current
            } else {
                Found::Other {
                    version: Some(version.to_owned()),
                }
            })
        }
        Channel::Nightly => {
            let response = get(
                client,
                format!("{}/repos/{REPOSITORY}/releases/tags/nightly", hosts.api),
            )
            .await?;
            match response.status {
                StatusCode::OK => {}
                // The nightly job deletes the old release before it creates the new one.
                StatusCode::NOT_FOUND => {
                    return Err(
                        "the nightly release is not there, maybe because CI publishes it now: try again in a \
                                few minutes"
                            .to_owned(),
                    );
                }
                status => return Err(format!("GitHub answered the release check with {status}")),
            }
            let release: NightlyRelease = serde_json::from_slice(&read(response).await?)
                .map_err(|error| format!("GitHub sent a nightly release that yuke cannot read: {error}"))?;
            // The build metadata of a nightly version is the start of its commit.
            let current_nightly = channel_of(current) == Some(Channel::Nightly)
                && (current.rsplit_once('+')).is_some_and(|(_, commit)| release.target_commitish.starts_with(commit));
            Ok(if current_nightly {
                Found::Current
            } else {
                Found::Other { version: None }
            })
        }
    }
}

/// Send a `GET` of `url`, and return the response at its head.
async fn get(client: &Client, url: String) -> Result<Response, String> {
    let request = Request::new(Method::GET, url.clone());
    (client.send(request, Some(Instant::now() + REQUEST_LIMIT)).await).map_err(|error| format!("{url}: {error}"))
}

/// Read the body of `response` to its end.
async fn read(mut response: Response) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response.body.chunk().await {
        bytes.extend_from_slice(&chunk.map_err(|error| format!("the download stopped: {error}"))?);
    }
    Ok(bytes)
}

/// Download the installer, and run it for the release `version`, or else for the newest release of `channel`. The
/// installer writes its own steps and errors.
async fn install(client: &Client, channel: Channel, version: Option<&str>) -> Result<(), String> {
    let response = get(client, INSTALLER.to_owned()).await?;
    if response.status != StatusCode::OK {
        return Err(format!("{INSTALLER}: {}", response.status));
    }
    let script = String::from_utf8_lossy(&read(response).await?).into_owned();
    let mut command = tokio::process::Command::new("bash");
    command
        .arg("-c")
        .arg(script)
        .arg("install.sh")
        .env("YUKE_CHANNEL", channel.name());
    // A YUKE_VERSION of the shell of the user selects a release that the user did not ask for here.
    match version {
        Some(version) => command.env("YUKE_VERSION", version),
        None => command.env_remove("YUKE_VERSION"),
    };
    let status = (command.status().await).map_err(|error| format!("yuke could not run bash: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("the installer failed".to_owned())
    }
}

/// Install the release `version`, or else the newest release of `channel`, or else the newest release of the channel
/// of the running build. `home` is the home folder of the user. The command refuses a yuke that the installer did not
/// write, because the installer replaces only `~/.local/bin/yuke`.
pub(crate) async fn update(
    version: Option<String>,
    channel: Option<Channel>,
    home: Option<&Path>,
) -> Result<ExitCode, String> {
    let current = env!("YUKE_VERSION");
    let home = home.ok_or("no home folder: set HOME")?;
    let program = std::env::current_exe().map_err(|error| format!("yuke could not find its program: {error}"))?;
    if !is_installed(&program, home) {
        return Err(format!(
            "the installer did not install {}: update it the way that you installed it",
            program.display()
        ));
    }
    // A version is a tagged release, and the stable channel holds the tags.
    let channel = match (&version, channel) {
        (Some(_), _) => Channel::Stable,
        (None, Some(channel)) => channel,
        (None, None) => channel_of(current).ok_or_else(|| {
            format!("yuke {current} is a build from source, so it has no channel: pass --channel or a VERSION")
        })?,
    };

    let client = Client::new(ClientOptions::new(crate::USER_AGENT)).map_err(|error| error.to_string())?;
    // The installer finds a missing version, so only a channel needs a check.
    let found = match &version {
        Some(version) if version == current => Found::Current,
        Some(version) => Found::Other {
            version: Some(version.clone()),
        },
        None => {
            progress(&format!("Checking the newest {} release", channel.name()));
            let hosts = Hosts {
                pages: "https://github.com".to_owned(),
                api: "https://api.github.com".to_owned(),
            };
            check(&client, &hosts, current, channel).await?
        }
    };
    let Found::Other { version: new } = found else {
        say(&format!("yuke is up to date ({current})."))?;
        return Ok(ExitCode::SUCCESS);
    };
    if let Some(new) = &new
        && is_older(new, current)
    {
        warn(&format!(
            "{new} is older than {current}, so it may not read the sessions that {current} saved"
        ));
    }

    progress("Downloading the installer");
    install(&client, channel, version.as_deref()).await?;
    let output = (tokio::process::Command::new(home.join(".local/bin/yuke"))
        .arg("--version")
        .output()
        .await)
        .map_err(|error| format!("the new yuke does not run: {error}"))?;
    let printed = String::from_utf8_lossy(&output.stdout);
    let installed = printed.trim().trim_start_matches("yuke ");
    say(&format!("Updated yuke {current} → {installed}. Restart open sessions."))?;
    Ok(ExitCode::SUCCESS)
}

#[cfg(test)]
mod tests;
