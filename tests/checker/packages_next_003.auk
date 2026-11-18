fn main() {
  print(markdown.html("# Hi\n\n*a* <script>x</script> [b](javascript:x)"))
  print(markdown.text("**t** &amp; u"))
}
