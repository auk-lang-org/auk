fn lookup(env: {str: str}, k: str): str? = env.get(k)
test "t" { assert lookup({"HOME": "x"}, "HOME") == some("x") }
