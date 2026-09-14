fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        // perf's libdw unwinder takes the load bias to be the mapping's
        // start minus its file offset, which is wrong for lld's default
        // layout, so host PCs use another function's unwind rules. Put
        // executable code in its own PT_LOAD segment at the same offset
        // in the file as in memory.
        println!("cargo::rustc-link-arg-bin=servicecache=-Wl,-z,separate-code");
    }
}
