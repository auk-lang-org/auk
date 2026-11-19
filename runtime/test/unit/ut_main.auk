/// The runtime's unit tests (runtime/test/unit/run.sh builds them with the runtime into one
/// program): `auk_rt_tests [name-filter]`. The groups run in the C runner's order.
export fn main(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>): i32 uses raw, ffi {
  if argc > 1 {
    ut.set_filter(argv.at(1))
  }
  test_arr.all()
  test_core.all()
  test_io.all()
  test_map.all()
  test_net.all()
  test_str.all()
  test_conc.all()
  ut.summary()
}
