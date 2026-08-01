// The server links the same C simulation core the client runs. One source of
// game rules, compiled here as a static library.
fn main() {
    cc::Build::new()
        .file("../sim/src/sim.c")
        .file("../sim/src/baseline.c")
        .file("../sim/src/pack.c")
        .include("../sim/include")
        .std("c99")
        .opt_level(2)
        .compile("sim");
    // Every source and header, or cargo keeps a stale library and the link
    // fails against a symbol that is plainly right there in the file. pack.c
    // was missing from this list, which is exactly how that presents.
    for f in [
        "../sim/src/sim.c",
        "../sim/src/baseline.c",
        "../sim/src/pack.c",
        "../sim/src/sintab.h",
        "../sim/include/sim/sim.h",
        "../sim/include/sim/baseline.h",
        "../sim/include/sim/pack.h",
    ] {
        println!("cargo:rerun-if-changed={f}");
    }
}
