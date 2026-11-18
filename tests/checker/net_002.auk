fn main(args: [str]): ()! uses net {
  var c = net.tls(args[1], int.parse(args[2])?)?
  c.write("GET / HTTP/1.0\r\nHost: {args[1]}\r\n\r\n".bytes())?
  let reply = str.from_utf8(c.read(4096)?)?
  print(reply.lines().first() else "")
  c.close()
}
