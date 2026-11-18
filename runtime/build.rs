//! Compiles the runtime's one C file: the setjmp/longjmp recovery points behind `catch`.
fn main() {
    println!("cargo:rerun-if-changed=src/catch.c");
    cc::Build::new().file("src/catch.c").opt_level(2).compile("auk_catch");
}
