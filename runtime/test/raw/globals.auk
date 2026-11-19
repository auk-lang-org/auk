raw struct Header { rc: i64, kind: u32, flags: u32 }
raw struct Str { h: Header, len_bytes: i64, len_chars: i64, is_ascii: bool, data: [u8; ..] }

raw let HEADER_SIZE: usize = raw.size_of<Header>()
raw let TWICE = HEADER_SIZE * 2
raw let SMALL: u8 = 250 + 10
raw assert raw.size_of<Str>() == 40
raw assert raw.offset_of<Str>(.data) == 33
raw assert TWICE == 32

raw var live_objects: i64 = 5
raw var proto: Header = Header { rc: 1, kind: 77 }
raw var ratio: f32 = 0.5
raw thread var depth: i32 = 3
raw var top: raw.Ptr<Header> = raw.null()
export var auk_test_flag: i32 = 9

fn run(): int uses raw {
  live_objects += 1
  depth += 1
  var bad = 0
  if live_objects != 6 { bad += 1 }
  if proto.kind != 77 || proto.rc != 1 { bad += 2 }
  if depth != 4 { bad += 4 }
  if !top.is_null() { bad += 8 }
  top = raw.addr_of(&proto)
  if top.kind != 77 { bad += 16 }
  if SMALL != 4 || TWICE != 32 { bad += 32 }
  if auk_test_flag != 9 || ratio != 0.5 { bad += 64 }
  bad
}

fn main(): int uses raw = run()
