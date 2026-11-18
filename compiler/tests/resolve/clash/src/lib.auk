/// A local module named like a dependency (E0101), a dependency that isn't installed (E0100)
/// and a module that doesn't parse: every load error, reported per file.
pub fn f(): int = util.g()
