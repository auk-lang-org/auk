/// Echo one message back, then close.
async fn serve(l: net.Listener): str! uses net {
  var c = l.accept()?
  var got: [int] = []
  while got.len() < 4 {
    let more = c.read(64)?
    if more.len() == 0 { break }
    got = got + more
  }
  c.write(got)?
  c.close()
  str.from_utf8(got)
}

/// Send "raft" and read until the server closes.
async fn client(port: int): str! uses net {
  var c = net.tcp("127.0.0.1", port)?
  c.write("raft".bytes())?
  var out: [int] = []
  var buf = c.read(64)?
  while buf.len() > 0 {
    out = out + buf
    buf = c.read(64)?
  }
  c.close()
  str.from_utf8(out)
}

test "echo over a listener" {
  var l = net.listen("127.0.0.1", 0)?
  assert l.port() > 0
  let (s, c) = await (serve(l), client(l.port()))
  assert s? == "raft"
  assert c? == "raft"
  l.close()
  assert l.accept() is err(_)
}

test "listen errors" {
  assert net.listen("127.0.0.1", 70000) is err(_)
  var a = net.listen("127.0.0.1", 0)?
  assert net.listen("127.0.0.1", a.port()) is err(_)
  a.close()
}
