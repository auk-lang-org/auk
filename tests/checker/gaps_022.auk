fn main() {
  let s = "  hi there \n"
  print("[{s.trim_start()}] [{s.trim_end()}] [{s.trim()}]")
  print("{"--flag".strip_prefix("--")} {"x".strip_prefix("--")} {"main.auk".strip_suffix(".auk")} {"héllo".strip_prefix("hé")}")
  let name = "file.txt".strip_suffix(".txt") else "?"
  print(name)
  print("{min(3, 1)} {max(3, 1)} {min("b", "a")} {max(2.5, -1.0)}")
  print("{"héllo ✓".byte_len()} {"".byte_len()} {"héllo".len()}")
}
