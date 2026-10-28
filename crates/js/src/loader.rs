//! The module names and the module loader. A built-in module has a `yuke:` name. A user module has the absolute path
//! of its file, so a stack trace names the file.

use std::path::{Component, Path, PathBuf};

use rquickjs::loader::{ImportAttributes, Loader, Resolver};
use rquickjs::module::Declared;
use rquickjs::{Ctx, Module};
use url::Url;

use crate::error::{ErrorClass, throw};
use crate::strip::{Cache, StripError};
use crate::{baked, native};

/// The prefix of the built-in modules that only a built-in module imports.
const INTERNAL: &str = "yuke:internal/";

/// The resolver of every module name. A built-in name and an absolute path stay as they are. A `./` or `../` name
/// starts in the folder of the importer. One resolver holds every rule, because the engine tries a second resolver
/// only after a failure that is not a throw.
#[derive(Debug)]
pub(crate) struct NameResolver {
    /// Every module can import the `yuke:internal/` modules, as in the tests of yuke.
    pub(crate) internal_imports: bool,
}

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
            if name.starts_with(INTERNAL) && !base.starts_with("yuke:") && !base.is_empty() && !self.internal_imports {
                return Err(throw(
                    ctx,
                    ErrorClass::TypeError,
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
                        ErrorClass::TypeError,
                        &format!("'{base}' cannot import '{name}' by a relative path"),
                    ));
                }
            }
        } else {
            return Err(throw(
                ctx,
                ErrorClass::TypeError,
                &format!("cannot resolve '{name}': a module name starts with 'yuke:', './', '../', or '/'"),
            ));
        };

        match normal(&path).into_os_string().into_string() {
            Ok(text) => Ok(text),
            Err(path) => Err(throw(
                ctx,
                ErrorClass::TypeError,
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
/// it is. A bytecode module gets its `yuke:` name as `import.meta.url`. A file module gets its `file:` URL, its
/// `filename`, and its `dirname`.
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
        if let Some(declared) = baked::load(ctx, name) {
            let module = declared?;
            module.meta()?.set("url", name)?;
            return Ok(module);
        }
        if name.starts_with("yuke:") {
            return Err(throw(
                ctx,
                ErrorClass::TypeError,
                &format!("no built-in module has the name '{name}'"),
            ));
        }

        let path = Path::new(name);
        let source = std::fs::read_to_string(path)
            .map_err(|error| throw(ctx, ErrorClass::Error, &format!("cannot read {name}: {error}")))?;

        let code = match path.extension().and_then(|extension| extension.to_str()) {
            Some("ts") => match self.cache.javascript(path, &source) {
                Ok(code) => code,
                Err(error @ StripError::Syntax(_)) => {
                    return Err(throw(ctx, ErrorClass::SyntaxError, &error.to_string()));
                }
                Err(error @ StripError::Cache(..)) => return Err(throw(ctx, ErrorClass::Error, &error.to_string())),
            },
            Some("js") => source,
            _ => {
                return Err(throw(
                    ctx,
                    ErrorClass::TypeError,
                    &format!("cannot load {name}: a module is a .ts or .js file"),
                ));
            }
        };

        let module = Module::declare(ctx.clone(), name, code)?;
        let url = Url::from_file_path(path)
            .map_err(|()| throw(ctx, ErrorClass::TypeError, &format!("{name} has no file URL")))?;
        let meta = module.meta()?;
        meta.set("url", url.as_str())?;
        meta.set("filename", name)?;
        meta.set("dirname", path.parent().and_then(Path::to_str))?;
        Ok(module)
    }
}

#[cfg(test)]
mod tests {
    use rquickjs::loader::Loader;
    use rquickjs::{Context, Runtime};

    use super::ModuleLoader;
    use crate::strip::Cache;

    #[test]
    fn a_built_in_module_has_its_name_as_its_url_and_no_folder() {
        let folder = yuke_testing::folder("js", "a_built_in_module_has_its_name_as_its_url_and_no_folder");
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();

        let (url, dirname) = context.with(|ctx| {
            let module = ModuleLoader::new(Cache::new(folder))
                .load(&ctx, "yuke:plugins", None)
                .unwrap();
            let meta = module.meta().unwrap();
            (
                meta.get::<_, String>("url").unwrap(),
                meta.contains_key("dirname").unwrap(),
            )
        });

        assert_eq!((url.as_str(), dirname), ("yuke:plugins", false));
    }
}
