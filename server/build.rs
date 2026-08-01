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
    println!("cargo:rerun-if-changed=../sim/src/sim.c");
    println!("cargo:rerun-if-changed=../sim/src/baseline.c");
    println!("cargo:rerun-if-changed=../sim/include/sim/sim.h");
}
