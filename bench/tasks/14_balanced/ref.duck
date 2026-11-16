fn balanced(s: str): bool {
  var stack: [char] = []
  for c in s.chars() {
    if c == '(' { stack.push(')') }
    else if c == '[' { stack.push(']') }
    else if c == '{' { stack.push('}') }
    else if c == ')' || c == ']' || c == '}' {
      if stack.pop() != some(c) { return false }
    }
  }
  stack.len() == 0
}
