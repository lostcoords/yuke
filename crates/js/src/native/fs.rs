//! The file operations of the native module for `yuke:fs`. Each one runs on a blocking thread of tokio and answers
//! `{ promise, cancel }`. `cancel` asks the operation to stop at its next check: before the work, between chunks of
//! 1 MiB, and before the rename of an atomic write. A failure rejects with a record `{ code, message, path,
//! destination }`, and a stop with `{ cancelled: true }`. `yuke:fs` turns each record into its public value.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use rquickjs::{Array, Ctx, Function, IntoJs, Object, Promise, TypedArray, Value};
use rustix::io::Errno;

use super::internal_record;
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
            Function::new(ctx.clone(), |ctx: Ctx<'js>, path: String, base: Option<String>| {
                read_text_file(&ctx, &path, base.as_deref())
            })?,
        ),
        (
            "fsWriteFile",
            Function::new(
                ctx.clone(),
                |ctx: Ctx<'js>,
                 path: String,
                 base: Option<String>,
                 data: Value<'js>,
                 atomic: bool,
                 mode: Option<u32>| { write_file(&ctx, &path, base.as_deref(), &data, atomic, mode) },
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
) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    // `yuke:fs` checks that both numbers are whole and in range.
    #[expect(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "a safe integer")]
    let (position, length) = (position as u64, length.map(|length| length as u64));
    operation(
        ctx,
        move |stop| read(&path, position, length, stop),
        |ctx, bytes| Ok(TypedArray::<u8>::new(ctx.clone(), bytes)?.into_value()),
    )
}

/// `fsReadTextFile(path, baseDir)`: the whole file as strict UTF-8.
fn read_text_file<'js>(ctx: &Ctx<'js>, path: &str, base: Option<&str>) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(
        ctx,
        move |stop| {
            let bytes = read(&path, 0, None, stop)?;
            String::from_utf8(bytes).map_err(|_| Failure::new(io::Error::from(Errno::ILSEQ), &path))
        },
        |ctx, text| text.into_js(ctx),
    )
}

/// `fsWriteFile(path, baseDir, data, atomic, mode)`: write `data`, a `Uint8Array` or a string, to a file.
fn write_file<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    data: &Value<'js>,
    atomic: bool,
    mode: Option<u32>,
) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    // A copy at the call, so a later change of the bytes does not reach the file.
    let bytes = match data.as_string() {
        Some(text) => text.to_string()?.into_bytes(),
        None => crate::bytes::copy(&TypedArray::<u8>::from_value(data.clone())?)?,
    };
    operation(ctx, move |stop| write(&path, &bytes, atomic, mode, stop), nothing)
}

/// `fsReadDir(path, baseDir)`: the entries of a directory.
fn read_dir_entries<'js>(ctx: &Ctx<'js>, path: &str, base: Option<&str>) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(
        ctx,
        move |stop| read_dir(&path, stop),
        |ctx, entries| {
            let array = Array::new(ctx.clone())?;
            for (index, entry) in entries.into_iter().enumerate() {
                let record = internal_record(ctx)?;
                record.set("name", entry.name)?;
                set_kind(&record, entry.kind)?;
                array.set(index, record)?;
            }
            Ok(array.into_value())
        },
    )
}

/// `fsStat(path, baseDir, follow)`: the facts of a path, of the target of a link when `follow`.
fn stat_path<'js>(ctx: &Ctx<'js>, path: &str, base: Option<&str>, follow: bool) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(
        ctx,
        move |stop| stat(&path, follow, stop),
        |ctx, info| {
            let record = internal_record(ctx)?;
            set_kind(&record, info.kind)?;
            record.set("size", info.size)?;
            record.set("mtime", info.modified)?;
            Ok(record.into_value())
        },
    )
}

/// `fsMkdir(path, baseDir, recursive, mode)`: create a directory.
fn make_dir<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    recursive: bool,
    mode: Option<u32>,
) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(
        ctx,
        move |stop| {
            stop.check()?;
            let mut builder = fs::DirBuilder::new();
            builder.recursive(recursive);
            if let Some(mode) = mode {
                builder.mode(mode);
            }
            builder.create(&path).map_err(|error| Failure::new(error, &path))
        },
        nothing,
    )
}

/// `fsRemove(path, baseDir, recursive, force)`: remove a path.
fn remove_path<'js>(
    ctx: &Ctx<'js>,
    path: &str,
    base: Option<&str>,
    recursive: bool,
    force: bool,
) -> rquickjs::Result<Object<'js>> {
    let path = resolve(ctx, path, base)?;
    operation(ctx, move |stop| remove(&path, recursive, force, stop), nothing)
}

/// `fsRename(source, destination, baseDir)`: move a path.
fn rename_path<'js>(
    ctx: &Ctx<'js>,
    source: &str,
    destination: &str,
    base: Option<&str>,
) -> rquickjs::Result<Object<'js>> {
    let source = resolve(ctx, source, base)?;
    let destination = resolve(ctx, destination, base)?;
    operation(
        ctx,
        move |stop| {
            stop.check()?;
            fs::rename(&source, &destination).map_err(|error| Failure {
                destination: Some(destination.clone()),
                ..Failure::new(error, &source)
            })
        },
        nothing,
    )
}

/// The value of an operation that gives nothing.
fn nothing<'js>(ctx: &Ctx<'js>, (): ()) -> rquickjs::Result<Value<'js>> {
    ().into_js(ctx)
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

/// The stop flag of one operation. `cancel` of JavaScript sets it, and the worker checks it.
#[derive(Debug, Clone, Default)]
struct Stop(Arc<AtomicBool>);

impl Stop {
    /// Fail with [`Failure::cancelled`] when a stop came.
    fn check(&self) -> Result<(), Failure> {
        if self.0.load(Ordering::Relaxed) {
            Err(Failure::cancelled())
        } else {
            Ok(())
        }
    }
}

/// Why an operation failed. `error` is `None` for a stop.
#[derive(Debug)]
struct Failure {
    error: Option<io::Error>,
    path: PathBuf,
    destination: Option<PathBuf>,
}

impl Failure {
    fn new(error: io::Error, path: &Path) -> Self {
        Failure {
            error: Some(error),
            path: path.to_owned(),
            destination: None,
        }
    }

    fn cancelled() -> Self {
        Failure {
            error: None,
            path: PathBuf::new(),
            destination: None,
        }
    }

    /// The record that the promise rejects with.
    fn record<'js>(self, ctx: &Ctx<'js>) -> rquickjs::Result<Object<'js>> {
        let record = internal_record(ctx)?;
        let Some(error) = self.error else {
            record.set("cancelled", true)?;
            return Ok(record);
        };
        let (code, description) = describe(&error);
        let path = self.path.to_string_lossy().into_owned();
        record.set("code", code)?;
        record.set("message", format!("{description}: {path}"))?;
        record.set("path", path)?;
        record.set(
            "destination",
            self.destination
                .map(|destination| destination.to_string_lossy().into_owned()),
        )?;
        Ok(record)
    }
}

/// The stable code and the description of `error`. The codes are the POSIX names that most runtimes give.
fn describe(error: &io::Error) -> (&'static str, String) {
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
    ];
    let errno = Errno::from_io_error(error);
    match CODES.iter().find(|(known, _, _)| Some(*known) == errno) {
        Some((_, code, description)) => (code, (*description).to_owned()),
        None => ("EIO", format!("the file system reported a failure ({error})")),
    }
}

/// Start `work` on a blocking thread, and give `{ promise, cancel }`. `convert` makes the value of the promise on the
/// JavaScript thread.
fn operation<'js, T: Send + 'static>(
    ctx: &Ctx<'js>,
    work: impl FnOnce(&Stop) -> Result<T, Failure> + Send + 'static,
    convert: impl FnOnce(&Ctx<'js>, T) -> rquickjs::Result<Value<'js>> + 'js,
) -> rquickjs::Result<Object<'js>> {
    let stop = Stop::default();
    let worker = stop.clone();
    let settle = ctx.clone();
    let promise = Promise::wrap_future(ctx, async move {
        let done = tokio::task::spawn_blocking(move || work(&worker)).await;
        // Each throw comes last, after the await, so no exception waits across it.
        match done {
            Ok(Ok(value)) => convert(&settle, value),
            Ok(Err(failure)) => Err(settle.throw(failure.record(&settle)?.into_value())),
            Err(error) => Err(throw(
                &settle,
                ErrorClass::Error,
                &format!("the file operation failed: {error}"),
            )),
        }
    })?;
    let cancel = Function::new(ctx.clone(), move || stop.0.store(true, Ordering::Relaxed))?;
    let record = internal_record(ctx)?;
    record.set("promise", promise)?;
    record.set("cancel", cancel)?;
    Ok(record)
}

/// The bytes of the file at `path` from `position`, at most `length`, or to the end. A directory and a special file
/// fail.
fn read(path: &Path, position: u64, length: Option<u64>, stop: &Stop) -> Result<Vec<u8>, Failure> {
    // The check before each chunk is the first check too. An open and a seek change nothing.
    let fail = |error| Failure::new(error, path);
    check_kind(fs::metadata(path).map_err(fail)?.file_type()).map_err(fail)?;
    let mut file = File::open(path).map_err(fail)?;
    file.seek(SeekFrom::Start(position)).map_err(fail)?;
    let mut reader = file.take(length.unwrap_or(u64::MAX));
    let mut bytes = Vec::new();
    loop {
        stop.check()?;
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

/// Write `bytes` to the file at `path`. Its folder must exist. `mode` sets the permissions of a new file. An atomic
/// write goes to a temporary file in the same folder and renames it over `path`, with the permissions of the file
/// that it replaces when `mode` is missing.
fn write(path: &Path, bytes: &[u8], atomic: bool, mode: Option<u32>, stop: &Stop) -> Result<(), Failure> {
    stop.check()?;
    let fail = |error| Failure::new(error, path);
    if !atomic {
        match fs::metadata(path) {
            Ok(metadata) => check_kind(metadata.file_type()).map_err(fail)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(fail(error)),
        }
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        if let Some(mode) = mode {
            options.mode(mode);
        }
        let mut file = options.open(path).map_err(fail)?;
        return write_chunks(&mut file, bytes, stop).map_err(|failure| failure.at(path));
    }

    let name = path.file_name().ok_or_else(|| fail(io::Error::from(Errno::ISDIR)))?;
    // Without `mode`, the new file keeps the permissions of the file that it replaces.
    let kept = match (mode, fs::metadata(path)) {
        (None, Ok(metadata)) if metadata.is_file() => Some(metadata.permissions().mode() & 0o7777),
        _ => None,
    };
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    if let Some(mode) = mode.or(kept) {
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
        write_chunks(&mut file, bytes, stop)?;
        // The rename shows the new file, so its bytes must reach the disk first.
        file.sync_all().map_err(|error| Failure::new(error, path))?;
        if let Some(mode) = kept {
            // The umask cuts the mode of a new file, and a kept mode must hold as it was.
            fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))
                .map_err(|error| Failure::new(error, path))?;
        }
        stop.check()?;
        fs::rename(&temporary, path).map_err(|error| Failure::new(error, path))
    })();
    if written.is_err() && fs::remove_file(&temporary).is_err() {
        // The temporary file stays. Its name says that it is one, and the failure still reaches the caller.
    }
    written.map_err(|failure| failure.at(path))
}

impl Failure {
    /// The same failure for `path`. A stop keeps no path.
    fn at(mut self, path: &Path) -> Self {
        if self.error.is_some() {
            path.clone_into(&mut self.path);
        }
        self
    }
}

/// Write `bytes` to `file` in chunks, with a stop check before each chunk.
fn write_chunks(file: &mut File, bytes: &[u8], stop: &Stop) -> Result<(), Failure> {
    for chunk in bytes.chunks(CHUNK) {
        stop.check()?;
        file.write_all(chunk)
            .map_err(|error| Failure::new(error, Path::new("")))?;
    }
    Ok(())
}

/// Refuse a directory with `EISDIR` and a special file with `EINVAL`. An open of a FIFO waits for its other end, so
/// the check comes before each open.
fn check_kind(kind: fs::FileType) -> io::Result<()> {
    if kind.is_dir() {
        Err(io::Error::from(Errno::ISDIR))
    } else if kind.is_file() {
        Ok(())
    } else {
        Err(io::Error::from(Errno::INVAL))
    }
}

/// What a path names, without a follow of a symbolic link for `Symlink`.
#[derive(Debug, Clone, Copy)]
enum Kind {
    File,
    Directory,
    Symlink,
    Other,
}

impl From<fs::FileType> for Kind {
    fn from(kind: fs::FileType) -> Self {
        if kind.is_symlink() {
            Kind::Symlink
        } else if kind.is_dir() {
            Kind::Directory
        } else if kind.is_file() {
            Kind::File
        } else {
            Kind::Other
        }
    }
}

/// Set `isFile`, `isDirectory`, and `isSymlink` of `record` for `kind`.
fn set_kind(record: &Object<'_>, kind: Kind) -> rquickjs::Result<()> {
    record.set("isFile", matches!(kind, Kind::File))?;
    record.set("isDirectory", matches!(kind, Kind::Directory))?;
    record.set("isSymlink", matches!(kind, Kind::Symlink))
}

/// One entry of a directory.
#[derive(Debug)]
struct Entry {
    name: String,
    kind: Kind,
}

/// The entries of the directory at `path`, in the order of the file system. A name that is not UTF-8 fails.
fn read_dir(path: &Path, stop: &Stop) -> Result<Vec<Entry>, Failure> {
    stop.check()?;
    let fail = |error| Failure::new(error, path);
    let mut entries = Vec::new();
    for entry in fs::read_dir(path).map_err(fail)? {
        stop.check()?;
        let entry = entry.map_err(fail)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| Failure::new(io::Error::from(Errno::ILSEQ), &entry.path()))?;
        let kind = entry.file_type().map_err(fail)?.into();
        entries.push(Entry { name, kind });
    }
    Ok(entries)
}

/// The facts of a path.
#[derive(Debug)]
struct Info {
    kind: Kind,
    size: f64,
    /// The time of the last change, in milliseconds since the epoch, when the file system gives one.
    modified: Option<f64>,
}

/// The facts of the path at `path`. `follow` reads the target of a symbolic link, and otherwise the link.
fn stat(path: &Path, follow: bool, stop: &Stop) -> Result<Info, Failure> {
    stop.check()?;
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
    Ok(Info {
        kind: metadata.file_type().into(),
        size,
        modified,
    })
}

/// Remove the file, the link, or the directory at `path`. A directory with entries needs `recursive`. `force` ignores a
/// missing path.
fn remove(path: &Path, recursive: bool, force: bool, stop: &Stop) -> Result<(), Failure> {
    stop.check()?;
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
