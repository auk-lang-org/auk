test "s" {
  assert "{n:>5} {if a { "x" } else { "y" }}" == """
    ok
    """
}
