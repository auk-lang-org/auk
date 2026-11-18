fn name(m: {str: str}): str = match m {
  {"name": v} => v
  _ => ""
}
