enum T { Eof, Word(s: str) }
fn f(t: T): str = match t {
  Eof => "end"
  other => "word"
}
