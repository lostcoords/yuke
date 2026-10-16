//! The module names and the module loader. A built-in module has a `yuke:` name. A user module has the absolute path
//! of its file, so a stack trace names the file.

use std::path::{Component, Path, PathBuf};

use rquickjs::loader::{ImportAttributes, Loader, Resolver};
use rquickjs::module::Declared;
use rquickjs::{Ctx, Module};

use crate::error::throw;
use crate::strip::{Cache, StripError};
use crate::{baked, native};

/// The prefix of the built-in modules that only a built-in module imports.
const INTERNAL: &str = "yuke:internal/";

/// The resolver of every module name. A built-in name and an absolute path stay as they are. A `./` or `../` name
/// starts in the folder of the importer. One resolver holds every rule, because the engine tries a second resolver
/// only after a failure that is not a throw.
#[derive(Debug)]
pub(crate) struct NameResolver;

impl Resolver for NameResolver {
    fn resolve<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        if name.starts_with("yuke:") {
            // An empty base is an import of the host itself, such as the plugin loader.
            if name.starts_with(INTERNAL) && !base.starts_with("yuke:") && !base.is_empty() {
                return Err(throw(
                    ctx,
                    "TypeError",
                    &format!("'{base}' cannot import '{name}': only a built-in module imports a yuke:internal module"),
                ));
            }
            // The loader refuses a `yuke:` name that no built-in module has.
            return Ok(name.to_owned());
        }

        let path = if Path::new(name).is_absolute() {
            PathBuf::from(name)
        } else if name.starts_with("./") || name.starts_with("../") {
            match Path::new(base).parent() {
                Some(folder) if Path::new(base).is_absolute() => folder.join(name),
                _ => {
                    return Err(throw(
                        ctx,
                        "TypeError",
                        &format!("'{base}' cannot import '{name}' by a relative path"),
                    ));
                }
            }
        } else {
            return Err(throw(
                ctx,
                "TypeError",
                &format!("cannot resolve '{name}': a module name starts with 'yuke:', './', '../', or '/'"),
            ));
        };

        match normal(&path).into_os_string().into_string() {
            Ok(text) => Ok(text),
            Err(path) => Err(throw(
                ctx,
                "TypeError",
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

/// Load a native module, the bytecode of a built-in module, a `.ts` file through the strip cache, or a `.js` file as
/// it is.
#[derive(Debug)]
pub(crate) struct ModuleLoader {
    cache: Cache,
}

impl ModuleLoader {
    pub(crate) fn new(cache: Cache) -> Self {
        Self { cache }
    }
}

impl Loader for ModuleLoader {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, Declared>> {
        if let Some(declared) = native::declare(ctx, name) {
            return declared;
        }
        if let Some(bytes) = baked::bytecode(name) {
            return baked::load(ctx, bytes);
        }
        if name.starts_with("yuke:") {
            return Err(throw(
                ctx,
                "TypeError",
                &format!("no built-in module has the name '{name}'"),
            ));
        }

        let path = Path::new(name);
        let source = std::fs::read_to_string(path)
            .map_err(|error| throw(ctx, "Error", &format!("cannot read {name}: {error}")))?;

        let code = match path.extension().and_then(|extension| extension.to_str()) {
            Some("ts") => match self.cache.javascript(path, &source) {
                Ok(code) => code,
                Err(error @ StripError::Syntax(_)) => return Err(throw(ctx, "SyntaxError", &error.to_string())),
                Err(error @ StripError::Cache(..)) => return Err(throw(ctx, "Error", &error.to_string())),
            },
            Some("js") => source,
            _ => {
                return Err(throw(
                    ctx,
                    "TypeError",
                    &format!("cannot load {name}: a module is a .ts or .js file"),
                ));
            }
        };

        Module::declare(ctx.clone(), name, code)
    }
}
