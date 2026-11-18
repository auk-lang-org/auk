shape Log { fn log(self, s: str) uses fs }
struct F { p: str }
fn log(f: F, s: str) uses fs { fs.write(f.p, s) else () }
fn report(l: any Log) uses fs { l.log("hi") }
fn main() uses fs { report(F { p: "a" }) }
