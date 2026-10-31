//! The calls of the `git` program for the plugin manager. Each call names the cache repository with `--git-dir`, and no
//! call runs a hook.

use std::io;
use std::path::Path;
use std::process::Stdio;

use tokio::process::Command;

/// Whether `text` is a full commit id: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
pub(crate) fn is_commit(text: &str) -> bool {
    matches!(text.len(), 40 | 64) && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// A `git` command on the cache repository `cache`, or on no repository.
fn git(cache: Option<&Path>) -> Command {
    let mut command = Command::new("git");
    if let Some(cache) = cache {
        command.arg("--git-dir").arg(cache);
    }
    // A hook of the user, such as `reference-transaction`, would run on each fetch.
    command.args(["-c", "core.hooksPath=/dev/null"]).kill_on_drop(true);
    // The terminal interface and the protocol server have no terminal for a question. The credential helper and the
    // ssh agent still serve.
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_ASKPASS", "")
        .stdin(Stdio::null());
    command
}

/// The text of a failed start of `program`.
fn start_error(program: &str, error: &io::Error) -> String {
    match error.kind() {
        io::ErrorKind::NotFound => format!("{program} not found on PATH"),
        _ => format!("{program}: {error}"),
    }
}

/// Run `command`, the `git` call `what`, and give its standard output. A failure gives the standard error of git.
async fn run(mut command: Command, what: &str) -> Result<String, String> {
    let output = command.output().await.map_err(|error| start_error("git", &error))?;
    if !output.status.success() {
        return Err(format!(
            "git {what}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout).map_err(|_| format!("git {what}: the output is not UTF-8"))
}

/// The full commit id that `reference` names in the repository `url`. `None` is the default branch, and a full commit id
/// names itself.
pub(crate) async fn resolve(url: &str, reference: Option<&str>) -> Result<String, String> {
    if let Some(reference) = reference
        && is_commit(reference)
    {
        return Ok(reference.to_owned());
    }
    // `ls-remote` matches the end of a ref name, so the names are full.
    let names = match reference {
        None => vec!["HEAD".to_owned()],
        Some(reference) => vec![
            format!("refs/tags/{reference}^{{}}"),
            format!("refs/tags/{reference}"),
            format!("refs/heads/{reference}"),
        ],
    };
    let mut command = git(None);
    command.args(["ls-remote", "--"]).arg(url).args(&names);
    let text = run(command, "ls-remote").await?;
    // The `^{}` line gives the commit of an annotated tag, and a tag wins over a branch of one name, as in git.
    names
        .iter()
        .find_map(|name| {
            text.lines().find_map(|line| {
                let (id, found) = line.split_once('\t')?;
                (found == name).then(|| id.to_owned())
            })
        })
        .ok_or_else(|| match reference {
            None => format!("{url} has no default branch"),
            Some(reference) => format!("{url} has no branch or tag '{reference}': fix \"ref\" in config.json"),
        })
}

/// Fetch the commit `commit` of `url` into the cache repository `cache`, unless the cache has it. The cache is made when
/// it is missing.
pub(crate) async fn fetch(cache: &Path, url: &str, commit: &str) -> Result<(), String> {
    if !cache.exists() {
        let mut init = git(None);
        init.args(["init", "--bare", "--quiet", "--template="]);
        // A cache of SHA-1 objects cannot fetch from a SHA-256 repository.
        if commit.len() == 64 {
            init.arg("--object-format=sha256");
        }
        init.arg(cache);
        run(init, "init").await?;
    }
    let mut has = git(Some(cache));
    has.args(["cat-file", "-e", "--end-of-options"])
        .arg(format!("{commit}^{{commit}}"));
    if run(has, "cat-file").await.is_ok() {
        return Ok(());
    }
    // The ref keeps the commit when git cleans the cache.
    let mut fetch = git(Some(cache));
    fetch
        .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--"])
        .arg(url)
        .arg(format!("+{commit}:refs/yuke/{commit}"));
    run(fetch, "fetch").await.map(|_| ())
}

/// Write the files of the commit `commit` of the cache repository `cache` into the empty folder `folder`, with no
/// `.git`.
pub(crate) async fn export(cache: &Path, commit: &str, folder: &Path) -> Result<(), String> {
    let mut archive = git(Some(cache));
    archive
        .args(["archive", "--format=tar", "--end-of-options", commit])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut archive = archive.spawn().map_err(|error| start_error("git", &error))?;
    let tar_input: Stdio = archive
        .stdout
        .take()
        .ok_or("git archive: no output")?
        .try_into()
        .map_err(|error: io::Error| format!("git archive: {error}"))?;
    let mut tar = Command::new("tar");
    tar.args(["-x", "-f", "-", "-C"])
        .arg(folder)
        .stdin(tar_input)
        .kill_on_drop(true);
    let (archived, extracted) = tokio::join!(archive.wait_with_output(), tar.output());
    // A failed `tar` closes the pipe, and then git fails too, so the error of `tar` comes first.
    let extracted = extracted.map_err(|error| start_error("tar", &error))?;
    if !extracted.status.success() {
        return Err(format!("tar: {}", String::from_utf8_lossy(&extracted.stderr).trim()));
    }
    let archived = archived.map_err(|error| format!("git archive: {error}"))?;
    if !archived.status.success() {
        return Err(format!(
            "git archive: {}",
            String::from_utf8_lossy(&archived.stderr).trim()
        ));
    }
    Ok(())
}

/// The commits after `old` up to `new` in the cache repository `cache`, newest first, as a short id and a subject.
pub(crate) async fn log(cache: &Path, old: &str, new: &str) -> Result<Vec<String>, String> {
    let mut log = git(Some(cache));
    log.args([
        "--no-pager",
        "log",
        "--no-show-signature",
        "--format=%h %s",
        "--end-of-options",
    ])
    .arg(format!("{old}..{new}"));
    Ok(run(log, "log").await?.lines().map(str::to_owned).collect())
}
