fn main() uses env, proc {
  let home = env.get("AUK_NO_SUCH_VAR") else proc.exit(0)
  print(home)
}
