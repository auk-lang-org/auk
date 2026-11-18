
extern fn blob(): [int] = "#embed data/all.bin"
extern fn blob_at(): ffi.Ptr = "#embed data/all.bin"
extern fn blob_len(): int = "#embed data/all.bin"
extern fn note(): str = "#embed data/note.txt"

fn main(args: [str]): ()! uses ffi, fs {
  let b = blob()
  print("{b.len()} {blob_len()} {b[0]} {b[255]} {b == ffi.bytes(blob_at(), blob_len())}")
  print("{ffi.read_u8(blob_at(), 10)} {note().trim()} {note().byte_len()}")
  fs.write_bytes(args[1], b)?
}
