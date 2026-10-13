//! Compile the built-in TypeScript modules of `modules/` to QuickJS bytecode. The name of a module is `yuke:` and its
//! path below `modules/` without `.ts`. The crate embeds the bytes through `OUT_DIR/baked.rs`.

#[path = "src/typescript.rs"]
mod typescript;

use std::error::Error;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use rquickjs::loader::{ImportAttributes, Loader, Resolver};
use rquickjs::module::Declared;
use rquickjs::{CatchResultExt, Context, Ctx, Module, Runtime, WriteOptions};

fn main() -> Result<(), Box<dyn Error>> {
    println!("cargo::rerun-if-changed=modules");
    println!("cargo::rerun-if-changed=src/typescript.rs");

    // The bytecode holds numbers in the byte order of the build host, and the engine reads it without a check.
    let host = if cfg!(target_endian = "little") {
        "little"
    } else {
        "big"
    };
    if std::env::var("CARGO_CFG_TARGET_ENDIAN")? != host {
        return Err("the built-in modules need a target with the byte order of the build host".into());
    }

    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?).join("modules");
    let output = PathBuf::from(std::env::var("OUT_DIR")?);
    let mut sources = Vec::new();
    collect(&root, &root, &mut sources)?;
    sources.sort();

    let runtime = Runtime::new()?;
    runtime.set_loader(KeepName, EmptyModule);
    let mut table = String::from("static MODULES: &[(&str, &[u8])] = &[\n");
    for (name, path) in sources {
        let source = std::fs::read_to_string(&path)?;
        let javascript = typescript::strip(&path, &source)?;
        let bytes = compile(&runtime, &name, &javascript)?;
        let file = output.join(format!("{}.qjsbc", name.replace([':', '/'], "_")));
        std::fs::write(&file, bytes)?;
        let file = file.to_str().ok_or("the output folder is not UTF-8")?;
        writeln!(table, "    ({name:?}, include_bytes!({file:?})),")?;
    }
    table.push_str("];\n");
    std::fs::write(output.join("baked.rs"), table)?;
    Ok(())
}

/// Add each `.ts` file below `folder` to `sources`, with its module name.
fn collect(root: &Path, folder: &Path, sources: &mut Vec<(String, PathBuf)>) -> Result<(), Box<dyn Error>> {
    for entry in std::fs::read_dir(folder)? {
        let path = entry?.path();
        if path.is_dir() {
            collect(root, &path, sources)?;
        } else if path.extension().is_some_and(|extension| extension == "ts") {
            let relative = path.strip_prefix(root)?.with_extension("");
            let relative = relative.to_str().ok_or("a module path is not UTF-8")?;
            sources.push((format!("yuke:{}", relative.replace('\\', "/")), path));
        }
    }
    Ok(())
}

/// The bytecode of the module `name`. Each module gets its own context, so the empty modules of the imports of one
/// module do not stand in for another module.
fn compile(runtime: &Runtime, name: &str, javascript: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let context = Context::full(runtime)?;
    context.with(|ctx| {
        let module = Module::declare(ctx.clone(), name, javascript)
            .catch(&ctx)
            .map_err(|error| format!("{name}: {error}"))?;
        // The source text goes, and the lines stay: a stack names them, and `import()` needs them.
        let options = WriteOptions {
            strip_source: true,
            ..WriteOptions::default()
        };
        Ok(module.write(options)?)
    })
}

/// Keep each name: the bytecode stores the name of an import as the source wrote it.
struct KeepName;

impl Resolver for KeepName {
    fn resolve<'js>(
        &mut self,
        _ctx: &Ctx<'js>,
        _base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        Ok(name.to_owned())
    }
}

/// An empty module for each import, because the engine loads the imports of a module that it declares.
struct EmptyModule;

impl Loader for EmptyModule {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, Declared>> {
        Module::declare(ctx.clone(), name, "")
    }
}
