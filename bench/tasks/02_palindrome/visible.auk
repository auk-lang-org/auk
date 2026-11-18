test "visible is_palindrome" {
  assert is_palindrome("A man, a plan, a canal: Panama")
  assert !is_palindrome("race a car")
}
