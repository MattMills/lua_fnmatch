// Makes the version of the stellar-fnmatch submodule available as STELLAR_FNMATCH_VERSION.

fn main() {
    let manifest = "../lib/stellar-fnmatch/Cargo.toml";
    println!("cargo:rerun-if-changed={}", manifest);
    let text = std::fs::read_to_string(manifest).unwrap_or_default();
    let version = text
        .lines()
        .skip_while(|l| l.trim() != "[package]")
        .find_map(|l| {
            let (k, v) = l.split_once('=')?;
            (k.trim() == "version").then(|| v.trim().trim_matches('"').to_string())
        })
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=STELLAR_FNMATCH_VERSION={}", version);
}
