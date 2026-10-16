//! Set the version that the command line and protocol report.

fn main() -> Result<(), std::env::VarError> {
    println!("cargo::rerun-if-env-changed=YUKE_BUILD_VERSION");
    let version = match std::env::var("YUKE_BUILD_VERSION") {
        Ok(version) => version,
        Err(std::env::VarError::NotPresent) => std::env::var("CARGO_PKG_VERSION")?,
        Err(error) => return Err(error),
    };
    println!("cargo::rustc-env=YUKE_VERSION={version}");
    Ok(())
}
