// The server links the same C simulation core the client runs. One source of
// game rules, compiled here as a static library.
fn main() {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let rustc_version = std::process::Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|version| version.trim().to_string())
        .unwrap_or_else(|| "unknown-rustc".into());
    println!("cargo:rustc-env=VW_RUSTC_VERSION={rustc_version}");

    for (cargo_name, rustc_name) in [
        ("PROFILE", "VW_BUILD_PROFILE"),
        ("OPT_LEVEL", "VW_BUILD_OPT_LEVEL"),
        ("DEBUG", "VW_BUILD_DEBUG"),
        ("TARGET", "VW_BUILD_TARGET"),
        ("HOST", "VW_BUILD_HOST"),
        ("CARGO_CFG_TARGET_FEATURE", "VW_BUILD_TARGET_FEATURES"),
        ("CARGO_ENCODED_RUSTFLAGS", "VW_BUILD_RUSTFLAGS"),
    ] {
        let value = std::env::var(cargo_name).unwrap_or_default();
        println!("cargo:rustc-env={rustc_name}={value}");
    }

    let mut sim = cc::Build::new();
    sim.file("../sim/src/sim.c")
        .file("../sim/src/baseline.c")
        .file("../sim/src/pack.c")
        .file("../sim/src/check.c")
        .include("../sim/include")
        .std("c99")
        .opt_level(2);
    let compiler = sim.get_compiler();
    let cc_version = std::process::Command::new(compiler.path())
        .arg("--version")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|version| version.lines().next().unwrap_or_default().to_string())
        .unwrap_or_else(|| "unknown-cc".into());
    let cc_identity = format!(
        "{}|{}|{:?}",
        compiler.path().display(),
        cc_version,
        compiler.args()
    );
    println!("cargo:rustc-env=VW_CC_IDENTITY={cc_identity}");
    sim.compile("sim");
    // Every source and header, or cargo keeps a stale library and the link
    // fails against a symbol that is plainly right there in the file. pack.c
    // was missing from this list, which is exactly how that presents.
    for f in [
        "../sim/src/sim.c",
        "../sim/src/baseline.c",
        "../sim/src/pack.c",
        "../sim/src/check.c",
        "../sim/src/sintab.h",
        "../sim/include/sim/sim.h",
        "../sim/include/sim/baseline.h",
        "../sim/include/sim/pack.h",
    ] {
        println!("cargo:rerun-if-changed={f}");
    }
    // The commit is read with `option_env!`, which cargo resolves at compile
    // time and will happily serve from cache. Without this, changing the
    // commit rebuilds nothing and every process reports the stamp of whenever
    // main.rs last changed, which is a deploy marker that lies.
    println!("cargo:rerun-if-env-changed=VW_COMMIT");
}
