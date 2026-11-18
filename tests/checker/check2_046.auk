shape Log { fn log(self, s: str) }
struct F { p: str }
fn log(f: F, s: str) uses fs { fs.write(f.p, s) else () }
fn report(l: any Log) { l.log("hi") }
fn main() { report(F { p: "a" }) }
