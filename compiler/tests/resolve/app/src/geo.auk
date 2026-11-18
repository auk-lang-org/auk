/// `geo` has a file and a folder (`geo/shapes.auk`): the folder's module is created first and
/// gets this file when the loader reaches it.

pub enum Shape { Round(c: shapes.Circle), Box(r: geo.shapes.Rect) }

pub struct Label { text: str }

pub fn label(s: str): Label = Label { text: s }
