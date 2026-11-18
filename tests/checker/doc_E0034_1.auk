fn name(m: {str: str}): str = match m {
  {k: v} => v
  _ => ""
}
