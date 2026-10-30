//! The file operations of the native module for `yuke:fs`. Each one runs on a blocking thread of tokio and answers
//! `{ promise, cancel }`. `cancel` asks the operation to stop at its next check: before the work, between chunks of
//! 1 MiB, and before the rename of an atomic write. A failure rejects with a record `{ code, message, path,
//! destination }`, and a stop with `{ cancelled: true }`. `yuke:fs` turns each record into its public value.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use rquickjs::{Ctx, Function, IntoJs, Object, TypedArray, Value};
use rustix::io::Errno;
use yuke_engine::CancellationToken;

use super::{Cancelled, Operation};
use crate::error::{ErrorClass, throw};

/// The bytes of one chunk of a read or a write. A stop takes effect between two chunks.
const CHUNK: usize = 1 << 20;

/// Add the file operations to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    // Each closure owns the arguments that rquickjs gives, and each operation borrows them.
    let functions: [(&str, Function<'js>); 8] = [
        (
            "fsReadFile",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, path: String, base: Option<String>, position: f64, length: Option<f64>| {
                    read_file(&ctx, &path, base.as_deref(), position, length)
                },
            )?,
        ),
        (
            "fsReadTextFile",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, path: String, base: Option<String>, fatal: bool| {
                    read_text_file(&ctx, &path, base.as_deref(), fatal)
                },
            )?,
        ),
        (
            "fsWriteFile",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>,
                 path: String,
                 base: Option<String>,
                 data: Value<'js>,
                 placement: String,
                 creation: String,
                 mode: Option<u32>| {
                    let how = (placement.as_str(), creation.as_str());
                    write_file(&ctx, &path, base.as_deref(), &data, how, mode)
                },
            )?,
        ),
        (
            "fsReadDir",
            Function::new(ctx.clone(), |ctx: Ctx<'js>, path: String, base: Option<String>| {
                read_dir_entries(&ctx, &path, base.as_deref())
            })?,
        ),
        (
            "fsStat",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, path: String, base: Option<String>, follow: bool| {
                    stat_path(&ctx, &path, base.as_deref(), follow)
                },
            )?,
        ),
        (
            "fsMkdir",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, path: String, base: Option<String>, recursive: bool, mode: Option<u32>| {
                    make_dir(&ctx, &path, base.as_deref(), recursive, mode)
                },
            )?,
        ),
        (
            "fsRemove",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, path: String, base: Option<String>, recursive: bool, force: bool| {
                    remove_path(&ctx, &path, base.as_deref(), recursive, force)
                },
            )?,
        ),
        (
            "fsRename",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>, source: String, destination: String, base: Option<String>| {
                    rename_path(&ctx, &source, &destination, base.as_deref())
                },
            )?,
        ),
    ];
    for (name, function) in functions {
        object.set(name, function)?;
    }
    Ok(())
}

/// `fsReadFile(path, baseDir, position, length)`: the bytes of a file from `position`, at most `length`.
fn read_file<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    position: f64,
    length: Option<f64>,
) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    // `yuke:fs` checks that both numbers are whole and in range.
    #[expect(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "a safe integer")]
    let (position, length) = (position as u64, length.map(|length| length as u64));
    operation(ctx, move |stop| read(&path, position, length, stop).map(Bytes))
}

/// `fsReadTextFile(path, baseDir, fatal)`: the whole file as UTF-8. Bytes that are not UTF-8 become U+FFFD, or fail
/// with `EILSEQ` when `fatal`.
fn read_text_file<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    fatal: bool,
) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| {
        let bytes = read(&path, 0, None, stop)?;
        match String::from_utf8(bytes) {
            Ok(text) => Ok(text),
            Err(_) if fatal => Err(Failure::new(io::Error::from(Errno::ILSEQ), &path)),
            Err(error) => Ok(String::from_utf8_lossy(error.as_bytes()).into_owned()),
        }
    })
}

/// How a write puts its bytes into the file.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Placement {
    /// Replace the content of the file.
    Replace,
    /// Add to the end of the file.
    Append,
    /// Write a temporary file and rename it over the path.
    Atomic,
}

/// When a write creates its file.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Creation {
    /// Create the file when it is missing.
    Create,
    /// Fail when the file is missing.
    Existing,
    /// Fail when the path exists.
    New,
}

/// `fsWriteFile(path, baseDir, data, placement, creation, mode)`: write `data`, a `Uint8Array` or a string, to a file.
/// `placement` is `replace`, `append`, or `atomic`; `creation` is `create`, `existing`, or `new`. `yuke:fs` sends
/// `atomic` only with `create`.
fn write_file<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    data: &Value<'js>,
    (placement, creation): (&str, &str),
    mode: Option<u32>,
) -> rquickjs::Result<Operation<'js>> {
    let placement = match placement {
        "replace" => Placement::Replace,
        "append" => Placement::Append,
        "atomic" => Placement::Atomic,
        _ => {
            return Err(throw(
                ctx,
                ErrorClass::TypeError,
                "the placement is not replace, append, or atomic",
            ));
        }
    };
    let creation = match creation {
        "create" => Creation::Create,
        "existing" => Creation::Existing,
        "new" => Creation::New,
        _ => {
            return Err(throw(
                ctx,
                ErrorClass::TypeError,
                "the creation is not create, existing, or new",
            ));
        }
    };
    let path = resolve(ctx, path, base)?;
    // A copy at the call, so a later change of the bytes does not reach the file.
    let bytes = match data.as_string() {
        Some(text) => text.to_string()?.into_bytes(),
        None => crate::bytes::copy(&TypedArray::<u8>::from_value(data.clone())?)?,
    };
    operation(ctx, move |stop| write(&path, &bytes, placement, creation, mode, stop))
}

/// `fsReadDir(path, baseDir)`: the entries of a directory.
fn read_dir_entries<'js>(ctx: &Ctx<'js>, path: &str, base: Option<&str>) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| read_dir(&path, stop))
}

/// `fsStat(path, baseDir, follow)`: the facts of a path, of the target of a link when `follow`.
fn stat_path<'js>(ctx: &Ctx<'js>, path: &str, base: Option<&str>, follow: bool) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| stat(&path, follow, stop))
}

/// `fsMkdir(path, baseDir, recursive, mode)`: create a directory.
fn make_dir<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    recursive: bool,
    mode: Option<u32>,
) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| {
        check(stop)?;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(recursive);
        if let Some(mode) = mode {
            builder.mode(mode);
        }
        builder.create(&path).map_err(|error| Failure::new(error, &path))
    })
}

/// `fsRemove(path, baseDir, recursive, force)`: remove a path.
fn remove_path<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    recursive: bool,
    force: bool,
) -> rquickjs::Result<Operation<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| remove(&path, recursive, force, stop))
}

/// `fsRename(source, destination, baseDir)`: move a path.
fn rename_path<'js>(
    ctx: &Ctx<'js>,
    source: &str,
    destination: &str,
    base: Option<&str>,
) -> rquickjs::Result<Operation<'js>> {
    let source = resolve(ctx, source, base)?;
    let destination = resolve(ctx, destination, base)?;
    operation(ctx, move |stop| {
        check(stop)?;
        fs::rename(&source, &destination).map_err(|error| Failure::Io {
            error,
            path: source.clone(),
            destination: Some(destination.clone()),
        })
    })
}

/// The bytes of a read, which JavaScript gets as a `Uint8Array`.
pub(crate) struct Bytes(pub(crate) Vec<u8>);

impl<'js> IntoJs<'js> for Bytes {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        Ok(TypedArray::<u8>::new(ctx.clone(), self.0)?.into_value())
    }
}

/// The absolute path of `path`. A relative path needs the absolute folder `base`. A bad path throws a `TypeError`.
fn resolve(ctx: &Ctx<'_>, path: &str, base: Option<&str>) -> rquickjs::Result<PathBuf> {
    let refuse = |message: &str| throw(ctx, ErrorClass::TypeError, message);
    if path.is_empty() {
        return Err(refuse("the path is empty"));
    }
    if path.contains('\0') || base.is_some_and(|base| base.contains('\0')) {
        return Err(refuse("a path holds a NUL character"));
    }
    if Path::new(path).is_absolute() {
        return Ok(PathBuf::from(path));
    }
    match base {
        Some(base) if Path::new(base).is_absolute() => Ok(Path::new(base).join(path)),
        Some(base) => Err(refuse(&format!("baseDir '{base}' is not an absolute path"))),
        None => Err(refuse(&format!("the relative path '{path}' needs baseDir"))),
    }
}

/// Fail with [`Failure::Cancelled`] after a call of `cancel`.
fn check(stop: &CancellationToken) -> Result<(), Failure> {
    if stop.is_cancelled() {
        Err(Failure::Cancelled)
    } else {
        Ok(())
    }
}

/// Why an operation failed.
#[derive(Debug)]
enum Failure {
    /// A call of `cancel` came before a check.
    Cancelled,
    /// The file system failed at `path`, or at the pair of `path` and `destination`.
    Io {
        error: io::Error,
        path: PathBuf,
        destination: Option<PathBuf>,
    },
}

impl Failure {
    fn new(error: io::Error, path: &Path) -> Self {
        Failure::Io {
            error,
            path: path.to_owned(),
            destination: None,
        }
    }

    /// The record that the promise rejects with.
    fn record<'js>(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        let Failure::Io {
            error,
            path,
            destination,
        } = self
        else {
            return Cancelled { cancelled: true }.into_js(ctx);
        };
        let (code, description) = describe(&error);
        let path = path.to_string_lossy().into_owned();
        FileError {
            code,
            message: format!("{description}: {path}"),
            path,
            destination: destination.map(|destination| destination.to_string_lossy().into_owned()),
        }
        .into_js(ctx)
    }
}

/// The record of a failed operation.
#[derive(IntoJs)]
struct FileError {
    code: &'static str,
    message: String,
    path: String,
    destination: Option<String>,
}

/// The stable code and the description of `error`. The codes are the POSIX names that most runtimes give.
pub(super) fn describe(error: &io::Error) -> (&'static str, String) {
    const CODES: &[(Errno, &str, &str)] = &[
        (Errno::NOENT, "ENOENT", "the path does not exist"),
        (Errno::EXIST, "EEXIST", "the path exists already"),
        (Errno::ACCESS, "EACCES", "the file system denied access to the path"),
        (
            Errno::PERM,
            "EPERM",
            "the file system does not permit the operation on the path",
        ),
        (Errno::NOTDIR, "ENOTDIR", "a part of the path is not a directory"),
        (Errno::ISDIR, "EISDIR", "the path is a directory"),
        (Errno::NOTEMPTY, "ENOTEMPTY", "the directory is not empty"),
        (Errno::XDEV, "EXDEV", "the paths are on different file systems"),
        (Errno::NOSPC, "ENOSPC", "the disk is full"),
        (Errno::ROFS, "EROFS", "the file system is read-only"),
        (Errno::LOOP, "ELOOP", "the path has too many symbolic links"),
        (Errno::NAMETOOLONG, "ENAMETOOLONG", "the path is too long"),
        (Errno::ILSEQ, "EILSEQ", "the bytes are not valid UTF-8"),
        (Errno::INVAL, "EINVAL", "the path names a special file"),
        (Errno::MFILE, "EMFILE", "the process has too many open files"),
        (Errno::NFILE, "ENFILE", "the system has too many open files"),
        (
            Errno::BUSY,
            "EBUSY",
            "a device or a resource that the path needs is busy",
        ),
        (
            Errno::TXTBSY,
            "ETXTBSY",
            "the system uses the file, for example as a running program",
        ),
        (Errno::FBIG, "EFBIG", "the file is too large"),
        (Errno::DQUOT, "EDQUOT", "the quota of the user on the disk is full"),
        (Errno::AGAIN, "EAGAIN", "the resource is not available now; try again"),
    ];
    let errno = Errno::from_io_error(error);
    match CODES.iter().find(|(known, _, _)| Some(*known) == errno) {
        Some((_, code, description)) => (code, (*description).to_owned()),
        None => ("EIO", format!("the file system reported a failure ({error})")),
    }
}

/// Start `work` on a blocking thread. The worker sees a call of `cancel` at its next check.
fn operation<'js, T: IntoJs<'js> + Send + 'static>(
    ctx: &Ctx<'js>,
    work: impl FnOnce(&CancellationToken) -> Result<T, Failure> + Send + 'static,
) -> rquickjs::Result<Operation<'js>> {
    Operation::start(ctx, move |ctx, stop| async move {
        let done = tokio::task::spawn_blocking(move || work(&stop)).await;
        // Each throw comes last, after the await, so no exception waits across it.
        match done {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(failure)) => Err(ctx.throw(failure.record(&ctx)?)),
            Err(error) => Err(throw(
                &ctx,
                ErrorClass::Error,
                &format!("the file operation failed: {error}"),
            )),
        }
    })
}

/// The bytes of the file at `path` from `position`, at most `length`, or to the end. A directory and a special file
/// fail.
fn read(path: &Path, position: u64, length: Option<u64>, stop: &CancellationToken) -> Result<Vec<u8>, Failure> {
    // The check before each chunk is the first check too. An open and a seek change nothing.
    let fail = |error| Failure::new(error, path);
    check_kind(fs::metadata(path).map_err(fail)?.file_type()).map_err(fail)?;
    let mut file = File::open(path).map_err(fail)?;
    file.seek(SeekFrom::Start(position)).map_err(fail)?;
    let mut reader = file.take(length.unwrap_or(u64::MAX));
    let mut bytes = Vec::new();
    loop {
        check(stop)?;
        let start = bytes.len();
        bytes.resize(start + CHUNK, 0);
        let count = reader.read(&mut bytes[start..]).map_err(fail)?;
        bytes.truncate(start + count);
        if count == 0 {
            return Ok(bytes);
        }
    }
}

/// The number of the next temporary file of this process.
static TEMPORARY: AtomicU64 = AtomicU64::new(0);

/// Write `bytes` to the file at `path` by `placement`, and create it by `creation`. Its folder must exist. `mode` sets
/// the permissions of the file, also of one that exists. An atomic write goes to a temporary file in the same folder
/// and renames it over `path`, with the permissions of the file that it replaces when `mode` is missing.
fn write(
    path: &Path,
    bytes: &[u8],
    placement: Placement,
    creation: Creation,
    mode: Option<u32>,
    stop: &CancellationToken,
) -> Result<(), Failure> {
    check(stop)?;
    let fail = |error| Failure::new(error, path);
    // A rename would replace a special file too, so both forms check the kind. A new file opens nothing that exists.
    let existing = match fs::metadata(path) {
        Ok(_) if creation == Creation::New => None,
        Ok(metadata) => {
            check_kind(metadata.file_type()).map_err(fail)?;
            Some(metadata)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(fail(error)),
    };
    if placement != Placement::Atomic {
        let mut options = OpenOptions::new();
        match placement {
            Placement::Append => options.append(true),
            Placement::Replace | Placement::Atomic => options.write(true).truncate(true),
        };
        match creation {
            Creation::Create => options.create(true),
            Creation::Existing => options.create(false),
            Creation::New => options.create_new(true),
        };
        if let Some(mode) = mode {
            options.mode(mode);
        }
        let mut file = options.open(path).map_err(fail)?;
        if let Some(mode) = mode {
            // `mode` holds for a file that exists too, and the umask does not cut it.
            file.set_permissions(fs::Permissions::from_mode(mode)).map_err(fail)?;
        }
        return write_chunks(&mut file, bytes, path, stop);
    }

    let name = path.file_name().ok_or_else(|| fail(io::Error::from(Errno::ISDIR)))?;
    // Without `mode`, the new file keeps the permissions of the file that it replaces.
    let wanted = mode.or_else(|| existing.map(|metadata| metadata.permissions().mode() & 0o7777));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    if let Some(mode) = wanted {
        options.mode(mode);
    }
    // A name that a crash left, or another process took, gives the next number.
    let (temporary, mut file) = loop {
        let number = TEMPORARY.fetch_add(1, Ordering::Relaxed);
        let temporary = path.with_file_name(format!(
            ".{}.{}-{number}.tmp",
            name.to_string_lossy(),
            std::process::id()
        ));
        match options.open(&temporary) {
            Ok(file) => break (temporary, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(fail(error)),
        }
    };
    let written = (|| {
        write_chunks(&mut file, bytes, path, stop)?;
        // The rename shows the new file, so its bytes must reach the disk first.
        file.sync_all().map_err(|error| Failure::new(error, path))?;
        if let Some(mode) = wanted {
            // The umask cuts the mode of a new file, and the mode must hold as it was.
            fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))
                .map_err(|error| Failure::new(error, path))?;
        }
        check(stop)?;
        fs::rename(&temporary, path).map_err(|error| Failure::new(error, path))
    })();
    if written.is_err() && fs::remove_file(&temporary).is_err() {
        // The temporary file stays. Its name says that it is one, and the failure still reaches the caller.
    }
    written
}

/// Write `bytes` to `file` in chunks, with a stop check before each chunk. An I/O failure names `path`.
fn write_chunks(file: &mut File, bytes: &[u8], path: &Path, stop: &CancellationToken) -> Result<(), Failure> {
    for chunk in bytes.chunks(CHUNK) {
        check(stop)?;
        file.write_all(chunk).map_err(|error| Failure::new(error, path))?;
    }
    Ok(())
}

/// Refuse a directory with `EISDIR` and a special file with `EINVAL`. An open of a FIFO waits for its other end, so
/// the check comes before each open.
pub(super) fn check_kind(kind: fs::FileType) -> io::Result<()> {
    if kind.is_dir() {
        Err(io::Error::from(Errno::ISDIR))
    } else if kind.is_file() {
        Ok(())
    } else {
        Err(io::Error::from(Errno::INVAL))
    }
}

/// One entry of a directory. The three kind checks are exclusive: a link is only a link.
#[derive(Debug, IntoJs)]
#[qjs(rename_all = "camelCase")]
struct Entry {
    name: String,
    is_file: bool,
    is_directory: bool,
    is_symlink: bool,
}

/// The entries of the directory at `path`, in the order of the file system. A name that is not UTF-8 fails.
fn read_dir(path: &Path, stop: &CancellationToken) -> Result<Vec<Entry>, Failure> {
    check(stop)?;
    let fail = |error| Failure::new(error, path);
    let mut entries = Vec::new();
    for entry in fs::read_dir(path).map_err(fail)? {
        check(stop)?;
        let entry = entry.map_err(fail)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| Failure::new(io::Error::from(Errno::ILSEQ), &entry.path()))?;
        let kind = entry.file_type().map_err(fail)?;
        entries.push(Entry {
            name,
            is_file: kind.is_file(),
            is_directory: kind.is_dir(),
            is_symlink: kind.is_symlink(),
        });
    }
    Ok(entries)
}

/// The facts of a path.
#[derive(Debug, IntoJs)]
#[qjs(rename_all = "camelCase")]
struct Info {
    /// The three kind checks are exclusive. A link that `stat` does not follow is only a link.
    is_file: bool,
    is_directory: bool,
    is_symlink: bool,
    size: f64,
    /// The time of the last change, in milliseconds since the epoch, when the file system gives one.
    mtime: Option<f64>,
}

/// The facts of the path at `path`. `follow` reads the target of a symbolic link, and otherwise the link.
fn stat(path: &Path, follow: bool, stop: &CancellationToken) -> Result<Info, Failure> {
    check(stop)?;
    let metadata = if follow {
        fs::metadata(path)
    } else {
        fs::symlink_metadata(path)
    }
    .map_err(|error| Failure::new(error, path))?;
    // A time before the epoch is a negative number of milliseconds.
    let modified = metadata
        .modified()
        .ok()
        .map(|time| match time.duration_since(UNIX_EPOCH) {
            Ok(after) => after.as_secs_f64() * 1000.0,
            Err(before) => -before.duration().as_secs_f64() * 1000.0,
        });
    #[expect(clippy::cast_precision_loss, reason = "a file of 2^53 bytes does not exist")]
    let size = metadata.len() as f64;
    let kind = metadata.file_type();
    Ok(Info {
        is_file: kind.is_file(),
        is_directory: kind.is_dir(),
        is_symlink: kind.is_symlink(),
        size,
        mtime: modified,
    })
}

/// Remove the file, the link, or the directory at `path`. A directory with entries needs `recursive`. `force` ignores a
/// missing path.
fn remove(path: &Path, recursive: bool, force: bool, stop: &CancellationToken) -> Result<(), Failure> {
    check(stop)?;
    let fail = |error| Failure::new(error, path);
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if force && error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(fail(error)),
    };
    let removed = match (metadata.is_dir(), recursive) {
        (true, true) => fs::remove_dir_all(path),
        (true, false) => fs::remove_dir(path),
        (false, _) => fs::remove_file(path),
    };
    match removed {
        Err(error) if force && error.kind() == io::ErrorKind::NotFound => Ok(()),
        removed => removed.map_err(fail),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use yuke_engine::CancellationToken;

    use super::{CHUNK, Creation, Failure, Placement, write};

    #[test]
    fn a_stop_during_an_atomic_write_leaves_the_old_file_and_no_temporary_file() {
        let folder = yuke_testing::folder(
            "js",
            "a_stop_during_an_atomic_write_leaves_the_old_file_and_no_temporary_file",
        );
        let path = folder.join("big.bin");
        fs::write(&path, "old").unwrap();
        let bytes = vec![0; 64 * CHUNK];
        let stop = CancellationToken::new();

        let written = std::thread::scope(|scope| {
            let writing = scope.spawn(|| write(&path, &bytes, Placement::Atomic, Creation::Create, None, &stop));
            // The temporary file shows that the write passed its first check. A write that ends first fails the test.
            while !writing.is_finished() && fs::read_dir(&folder).unwrap().count() < 2 {
                std::thread::yield_now();
            }
            stop.cancel();
            writing.join().unwrap()
        });

        assert!(matches!(written, Err(Failure::Cancelled)), "{written:?}");
        assert_eq!(fs::read(&path).unwrap(), b"old");
        let names: Vec<_> = fs::read_dir(&folder)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["big.bin"]);
    }
}
