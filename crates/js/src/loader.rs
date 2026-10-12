//! The module names and the module loader. A module name is the absolute path of its file, so a stack trace names the
//! file.

use std::path::{Component, Path, PathBuf};

use rquickjs::loader::{ImportAttributes, Loader, Resolver};
use rquickjs::module::Declared;
use rquickjs::{Ctx, Exception, Module};

use crate::strip::{Cache, StripError};

/// Resolve `./` and `../` names against the folder of the importer, and keep absolute paths.
#[derive(Debug)]
pub(crate) struct PathResolver;

impl Resolver for PathResolver {
    fn resolve<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        let path = if Path::new(name).is_absolute() {
            PathBuf::from(name)
        } else if name.starts_with("./") || name.starts_with("../") {
            match Path::new(base).parent() {
                Some(folder) if Path::new(base).is_absolute() => folder.join(name),
                _ => {
                    return Err(Exception::throw_type(
                        ctx,
                        &format!("'{base}' cannot import '{name}' by a relative path"),
                    ));
                }
            }
        } else {
            return Err(Exception::throw_type(
                ctx,
                &format!("cannot resolve '{name}': a module name starts with './', '../', or '/'"),
            ));
        };

        match normal(&path).into_os_string().into_string() {
            Ok(text) => Ok(text),
            Err(path) => Err(Exception::throw_type(
                ctx,
                &format!("the module path {} is not UTF-8", path.display()),
            )),
        }
    }
}

/// The path without `.` and `..` parts, so two names of one file give one module. Symbolic links stay.
fn normal(path: &Path) -> PathBuf {
    let mut normal = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normal.pop();
            }
            other => normal.push(other),
        }
    }
    normal
}

/// Load a `.ts` file through the strip cache, and a `.js` file as it is.
#[derive(Debug)]
pub(crate) struct FileLoader {
    cache: Cache,
}

impl FileLoader {
    pub(crate) fn new(cache: Cache) -> Self {
        Self { cache }
    }
}

impl Loader for FileLoader {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, Declared>> {
        let path = Path::new(name);
        let source = std::fs::read_to_string(path)
            .map_err(|error| Exception::throw_message(ctx, &format!("cannot read {name}: {error}")))?;

        let code = match path.extension().and_then(|extension| extension.to_str()) {
            Some("ts") => match self.cache.javascript(path, &source) {
                Ok(code) => code,
                Err(error @ StripError::Syntax(_)) => return Err(Exception::throw_syntax(ctx, &error.to_string())),
                Err(error @ StripError::Cache(..)) => return Err(Exception::throw_message(ctx, &error.to_string())),
            },
            Some("js") => source,
            _ => {
                return Err(Exception::throw_type(
                    ctx,
                    &format!("cannot load {name}: a module is a .ts or .js file"),
                ));
            }
        };

        Module::declare(ctx.clone(), name, code)
    }
}
