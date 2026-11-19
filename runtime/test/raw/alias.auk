// `raw type` aliases: transparent names for raw types (a C typedef), in this module and
// another's by path (`facts.ModeT`, as per-target files declare them).

raw type Count = u32
raw type RetainFn = raw.Fn<(raw.Ptr<()>) => ()>
raw type Words = [Count; 4]
raw struct Ops { retain: RetainFn, n: Count, w: Words }

raw var hits: Count = 0

export fn bump(p: raw.Ptr<()>) uses raw { hits += 1 }

raw let OPS: Ops = Ops { retain: raw.fn_of(bump), n: 3 }

fn mode(m: facts.ModeT): u32 = u32(m) + 1

fn run(): int uses raw {
  var bad = 0
  let f: RetainFn = OPS.retain
  f(raw.null())
  f(raw.null())
  let n: u32 = hits
  if n != 2 || OPS.n != 3 { bad += 1 }
  let m: facts.ModeT = facts.S_IFDIR
  if mode(m) != 0x4001 { bad += 2 }
  if raw.size_of<Ops>() != 8 + 4 + 16 + 4 { bad += 4 }
  bad
}

fn main(): int uses raw = run()
