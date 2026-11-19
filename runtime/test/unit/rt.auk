/// The runtime's API as the unit tests call it (runtime/test/unit, the port of runtime/c/test):
/// the functions of auk_rt.h the tests use, under their C names (an `extern fn` of a symbol the
/// package defines calls that definition, as `#include "auk_rt.h"` did for the C tests), the
/// element-ops tables and the C library. The runtime's objects are `raw.Ptr<abi.…>`; function
/// pointers C may get as NULL are `raw.Ptr<()>` (pass `raw.cast<()>(raw.fn_of(f))`), the others
/// `raw.Fn`.

// ---- the runtime (auk_rt.h) ------------------------------------------------------------------

pub extern fn auk_add(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_add(int64_t, int64_t, void *)"
pub extern fn auk_arr_at(a: raw.Ptr<abi.Arr>, i: i64, loc: raw.Ptr<u8>): raw.Ptr<()> =
  "void *auk_arr_at(void *, int64_t, void *)"
pub extern fn auk_arr_clear(pa: raw.Ptr<raw.Ptr<abi.Arr>>) =
  "void auk_arr_clear(void *)"
pub extern fn auk_arr_cmp(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): i32 =
  "int auk_arr_cmp(void *, void *)"
pub extern fn auk_arr_concat(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> =
  "void *auk_arr_concat(void *, void *)"
pub extern fn auk_arr_contains(a: raw.Ptr<abi.Arr>, e: raw.Ptr<()>): bool =
  "bool auk_arr_contains(void *, void *)"
pub extern fn auk_arr_copy(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> =
  "void *auk_arr_copy(void *)"
pub extern fn auk_arr_data(a: raw.Ptr<abi.Arr>): raw.Ptr<()> =
  "void *auk_arr_data(void *)"
pub extern fn auk_arr_eq(a: raw.Ptr<abi.Arr>, b: raw.Ptr<abi.Arr>): bool =
  "bool auk_arr_eq(void *, void *)"
pub extern fn auk_arr_extend(pa: raw.Ptr<raw.Ptr<abi.Arr>>, b: raw.Ptr<abi.Arr>) =
  "void auk_arr_extend(void *, void *)"
pub extern fn auk_arr_from(ops: raw.Ptr<abi.ElemOps>, elems: raw.Ptr<()>, n: i64): raw.Ptr<abi.Arr> =
  "void *auk_arr_from(void *, void *, int64_t)"
pub extern fn auk_arr_get_opt(a: raw.Ptr<abi.Arr>, i: i64, out: raw.Ptr<()>): bool =
  "bool auk_arr_get_opt(void *, int64_t, void *)"
pub extern fn auk_arr_hash(a: raw.Ptr<abi.Arr>): u64 =
  "uint64_t auk_arr_hash(void *)"
pub extern fn auk_arr_index_of(a: raw.Ptr<abi.Arr>, e: raw.Ptr<()>): abi.OptInt =
  "AukOpt_int auk_arr_index_of(void *, void *)"
pub extern fn auk_arr_insert(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, e: raw.Ptr<()>, loc: raw.Ptr<u8>) =
  "void auk_arr_insert(void *, int64_t, void *, void *)"
pub extern fn auk_arr_join(a: raw.Ptr<abi.Arr>, sep: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_arr_join(void *, void *)"
pub extern fn auk_arr_len(a: raw.Ptr<abi.Arr>): i64 =
  "int64_t auk_arr_len(void *)"
pub extern fn auk_arr_make_unique(pa: raw.Ptr<raw.Ptr<abi.Arr>>): raw.Ptr<()> =
  "void *auk_arr_make_unique(void *)"
pub extern fn auk_arr_new(ops: raw.Ptr<abi.ElemOps>, cap: i64): raw.Ptr<abi.Arr> =
  "void *auk_arr_new(void *, int64_t)"
pub extern fn auk_arr_pop(pa: raw.Ptr<raw.Ptr<abi.Arr>>, out: raw.Ptr<()>): bool =
  "bool auk_arr_pop(void *, void *)"
pub extern fn auk_arr_push(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) =
  "void auk_arr_push(void *, void *)"
pub extern fn auk_arr_push_own(pa: raw.Ptr<raw.Ptr<abi.Arr>>, e: raw.Ptr<()>) =
  "void auk_arr_push_own(void *, void *)"
pub extern fn auk_arr_remove(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, out: raw.Ptr<()>, loc: raw.Ptr<u8>) =
  "void auk_arr_remove(void *, int64_t, void *, void *)"
pub extern fn auk_arr_reverse(pa: raw.Ptr<raw.Ptr<abi.Arr>>) =
  "void auk_arr_reverse(void *)"
pub extern fn auk_arr_reversed(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> =
  "void *auk_arr_reversed(void *)"
pub extern fn auk_arr_set(pa: raw.Ptr<raw.Ptr<abi.Arr>>, i: i64, e: raw.Ptr<()>, loc: raw.Ptr<u8>) =
  "void auk_arr_set(void *, int64_t, void *, void *)"
pub extern fn auk_arr_show(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> =
  "void *auk_arr_show(void *)"
pub extern fn auk_arr_skip(a: raw.Ptr<abi.Arr>, n: i64): raw.Ptr<abi.Arr> =
  "void *auk_arr_skip(void *, int64_t)"
pub extern fn auk_arr_slice(a: raw.Ptr<abi.Arr>, lo: i64, hi: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> =
  "void *auk_arr_slice(void *, int64_t, int64_t, void *)"
pub extern fn auk_arr_sort(pa: raw.Ptr<raw.Ptr<abi.Arr>>) =
  "void auk_arr_sort(void *)"
pub extern fn auk_arr_sort_with(pa: raw.Ptr<raw.Ptr<abi.Arr>>, cmp: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>, raw.Ptr<()>) => i32>, ctx: raw.Ptr<()>) =
  "void auk_arr_sort_with(void *, void *, void *)"
pub extern fn auk_arr_sorted(a: raw.Ptr<abi.Arr>): raw.Ptr<abi.Arr> =
  "void *auk_arr_sorted(void *)"
pub extern fn auk_arr_sum_int(a: raw.Ptr<abi.Arr>, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_arr_sum_int(void *, void *)"
pub extern fn auk_arr_take(a: raw.Ptr<abi.Arr>, n: i64): raw.Ptr<abi.Arr> =
  "void *auk_arr_take(void *, int64_t)"
pub extern fn auk_assert_fail_cmp(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>, left: raw.Ptr<abi.Str>, right: raw.Ptr<abi.Str>): never =
  "void auk_assert_fail_cmp(void *, void *, void *, void *)"
pub extern fn auk_cancel_check(loc: raw.Ptr<u8>) =
  "void auk_cancel_check(void *)"
pub extern fn auk_catch(f: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, env: raw.Ptr<()>, out: raw.Ptr<()>): raw.Ptr<abi.Err> =
  "void *auk_catch(void *, void *, void *)"
pub extern fn auk_chan_close(c: raw.Ptr<abi.Chan>) =
  "void auk_chan_close(void *)"
pub extern fn auk_chan_new(proto: raw.Ptr<abi.Arr>): raw.Ptr<abi.Chan> =
  "void *auk_chan_new(void *)"
pub extern fn auk_chan_recv(c: raw.Ptr<abi.Chan>, out: raw.Ptr<()>): bool =
  "bool auk_chan_recv(void *, void *)"
pub extern fn auk_chan_recv_for(c: raw.Ptr<abi.Chan>, ms: i64, out: raw.Ptr<()>): bool =
  "bool auk_chan_recv_for(void *, int64_t, void *)"
pub extern fn auk_chan_send(c: raw.Ptr<abi.Chan>, x: raw.Ptr<()>, loc: raw.Ptr<u8>) =
  "void auk_chan_send(void *, void *, void *)"
pub extern fn auk_char_from_int(n: i64): abi.OptChar =
  "AukOpt_char auk_char_from_int(int64_t)"
pub extern fn auk_char_is_alpha(c: u32): bool =
  "bool auk_char_is_alpha(uint32_t)"
pub extern fn auk_char_is_digit(c: u32): bool =
  "bool auk_char_is_digit(uint32_t)"
pub extern fn auk_char_is_space(c: u32): bool =
  "bool auk_char_is_space(uint32_t)"
pub extern fn auk_char_lower(c: u32): u32 =
  "uint32_t auk_char_lower(uint32_t)"
pub extern fn auk_char_quote(c: u32): raw.Ptr<abi.Str> =
  "void *auk_char_quote(uint32_t)"
pub extern fn auk_char_upper(c: u32): u32 =
  "uint32_t auk_char_upper(uint32_t)"
pub extern fn auk_closure_release(c: abi.Closure) =
  "void auk_closure_release(AukClosure)"
pub extern fn auk_conn_close(c: raw.Ptr<abi.Conn>) =
  "void auk_conn_close(void *)"
pub extern fn auk_conn_read(c: raw.Ptr<abi.Conn>, max: i64): abi.ResArr =
  "AukRes_arr auk_conn_read(void *, int64_t)"
pub extern fn auk_conn_write(c: raw.Ptr<abi.Conn>, bytes: raw.Ptr<abi.Arr>): abi.ResUnit =
  "AukRes_unit auk_conn_write(void *, void *)"
pub extern fn auk_dbg_enter(f: raw.Ptr<abi.DbgFrame>) =
  "void auk_dbg_enter(void *)"
pub extern fn auk_dbg_hook(f: raw.Ptr<abi.DbgFrame>) =
  "void auk_dbg_hook(void *)"
pub extern fn auk_dbg_init(text: raw.Ptr<u8>, shows: raw.Ptr<()>, kids: raw.Ptr<()>) =
  "void auk_dbg_init(void *, void *, void *)"
pub extern fn auk_dbg_leave(f: raw.Ptr<abi.DbgFrame>) =
  "void auk_dbg_leave(void *)"
pub extern fn auk_div(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_div(int64_t, int64_t, void *)"
pub extern fn auk_ensures_fail(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>): never =
  "void auk_ensures_fail(void *, void *)"
pub extern fn auk_env_args(): raw.Ptr<abi.Arr> =
  "void *auk_env_args(void)"
pub extern fn auk_env_get(key: raw.Ptr<abi.Str>): abi.OptStr =
  "AukOpt_str auk_env_get(void *)"
pub extern fn auk_env_lines(): raw.Ptr<abi.Arr> =
  "void *auk_env_lines(void)"
pub extern fn auk_env_read_all(): abi.ResStr =
  "AukRes_str auk_env_read_all(void)"
pub extern fn auk_env_read_line(): abi.OptStr =
  "AukOpt_str auk_env_read_line(void)"
pub extern fn auk_env_set_args(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>) =
  "void auk_env_set_args(int, void *)"
pub extern fn auk_eprint(s: raw.Ptr<abi.Str>) =
  "void auk_eprint(void *)"
pub extern fn auk_err_payload(e: raw.Ptr<abi.Err>, type_id: u32): raw.Ptr<()> =
  "void *auk_err_payload(void *, uint32_t)"
pub extern fn auk_err_show(e: raw.Ptr<abi.Err>): raw.Ptr<abi.Str> =
  "void *auk_err_show(void *)"
pub extern fn auk_err_typed(type_id: u32, value_: raw.Ptr<()>, ops: raw.Ptr<abi.ElemOps>, msg: raw.Ptr<abi.Str>): raw.Ptr<abi.Err> =
  "void *auk_err_typed(uint32_t, void *, void *, void *)"
pub extern fn auk_err_wrap(msg: raw.Ptr<abi.Str>, cause: raw.Ptr<abi.Err>): raw.Ptr<abi.Err> =
  "void *auk_err_wrap(void *, void *)"
pub extern fn auk_facos(a: float): float =
  "double auk_facos(double)"
pub extern fn auk_fasin(a: float): float =
  "double auk_fasin(double)"
pub extern fn auk_fatan(a: float): float =
  "double auk_fatan(double)"
pub extern fn auk_fatan2(y: float, x: float): float =
  "double auk_fatan2(double, double)"
pub extern fn auk_fbits(a: float): i64 =
  "int64_t auk_fbits(double)"
pub extern fn auk_fbits32(a: float): i64 =
  "int64_t auk_fbits32(double)"
pub extern fn auk_fceil(a: float): float =
  "double auk_fceil(double)"
pub extern fn auk_fcos(a: float): float =
  "double auk_fcos(double)"
pub extern fn auk_fexp(a: float): float =
  "double auk_fexp(double)"
pub extern fn auk_ffloor(a: float): float =
  "double auk_ffloor(double)"
pub extern fn auk_ffrom_bits(n: i64): float =
  "double auk_ffrom_bits(int64_t)"
pub extern fn auk_ffrom_bits32(n: i64): float =
  "double auk_ffrom_bits32(int64_t)"
pub extern fn auk_fln(a: float): float =
  "double auk_fln(double)"
pub extern fn auk_float_cmp(a: float, b: float): i32 =
  "int auk_float_cmp(double, double)"
pub extern fn auk_float_parse(s: raw.Ptr<abi.Str>): abi.ResFloat =
  "AukRes_float auk_float_parse(void *)"
pub extern fn auk_float_to_int(x: float, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_float_to_int(double, void *)"
pub extern fn auk_flog10(a: float): float =
  "double auk_flog10(double)"
pub extern fn auk_flog2(a: float): float =
  "double auk_flog2(double)"
pub extern fn auk_fmt_bool(v: bool, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_fmt_bool(bool, void *)"
pub extern fn auk_fmt_char(c: u32, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_fmt_char(uint32_t, void *)"
pub extern fn auk_fmt_float(v: float, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_fmt_float(double, void *)"
pub extern fn auk_fmt_int(v: i64, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_fmt_int(int64_t, void *)"
pub extern fn auk_fmt_str(s: raw.Ptr<abi.Str>, spec: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_fmt_str(void *, void *)"
pub extern fn auk_fpow(a: float, b: float): float =
  "double auk_fpow(double, double)"
pub extern fn auk_fround(a: float): float =
  "double auk_fround(double)"
pub extern fn auk_fs_append(path: raw.Ptr<abi.Str>, text: raw.Ptr<abi.Str>): abi.ResUnit =
  "AukRes_unit auk_fs_append(void *, void *)"
pub extern fn auk_fs_exists(path: raw.Ptr<abi.Str>): bool =
  "bool auk_fs_exists(void *)"
pub extern fn auk_fs_is_dir(path: raw.Ptr<abi.Str>): bool =
  "bool auk_fs_is_dir(void *)"
pub extern fn auk_fs_lines(path: raw.Ptr<abi.Str>): abi.ResArr =
  "AukRes_arr auk_fs_lines(void *)"
pub extern fn auk_fs_list(dir: raw.Ptr<abi.Str>): abi.ResArr =
  "AukRes_arr auk_fs_list(void *)"
pub extern fn auk_fs_mkdir(path: raw.Ptr<abi.Str>): abi.ResUnit =
  "AukRes_unit auk_fs_mkdir(void *)"
pub extern fn auk_fs_read(path: raw.Ptr<abi.Str>): abi.ResStr =
  "AukRes_str auk_fs_read(void *)"
pub extern fn auk_fs_read_bytes(path: raw.Ptr<abi.Str>): abi.ResArr =
  "AukRes_arr auk_fs_read_bytes(void *)"
pub extern fn auk_fs_remove(path: raw.Ptr<abi.Str>): abi.ResUnit =
  "AukRes_unit auk_fs_remove(void *)"
pub extern fn auk_fs_rename(from_: raw.Ptr<abi.Str>, to_: raw.Ptr<abi.Str>): abi.ResUnit =
  "AukRes_unit auk_fs_rename(void *, void *)"
pub extern fn auk_fs_temp_dir(): abi.ResStr =
  "AukRes_str auk_fs_temp_dir(void)"
pub extern fn auk_fs_write(path: raw.Ptr<abi.Str>, content: raw.Ptr<abi.Str>): abi.ResUnit =
  "AukRes_unit auk_fs_write(void *, void *)"
pub extern fn auk_fs_write_bytes(path: raw.Ptr<abi.Str>, bytes: raw.Ptr<abi.Arr>): abi.ResUnit =
  "AukRes_unit auk_fs_write_bytes(void *, void *)"
pub extern fn auk_fsin(a: float): float =
  "double auk_fsin(double)"
pub extern fn auk_fsqrt(a: float): float =
  "double auk_fsqrt(double)"
pub extern fn auk_ftan(a: float): float =
  "double auk_ftan(double)"
pub extern fn auk_heap_new(): raw.Ptr<()> =
  "void *auk_heap_new(void)"
pub extern fn auk_heap_switch(h: raw.Ptr<()>): raw.Ptr<()> =
  "void *auk_heap_switch(void *)"
pub extern fn auk_hole(loc: raw.Ptr<u8>, expected: raw.Ptr<u8>): never =
  "void auk_hole(void *, void *)"
pub extern fn auk_int_cmp(a: i64, b: i64): i32 =
  "int auk_int_cmp(int64_t, int64_t)"
pub extern fn auk_int_parse(s: raw.Ptr<abi.Str>): abi.ResInt =
  "AukRes_int auk_int_parse(void *)"
pub extern fn auk_leak_baseline() =
  "void auk_leak_baseline(void)"
pub extern fn auk_leak_check(): i64 =
  "int64_t auk_leak_check(void)"
pub extern fn auk_listener_accept(l: raw.Ptr<abi.Listener>): abi.ResConn =
  "AukRes_conn auk_listener_accept(void *)"
pub extern fn auk_listener_close(l: raw.Ptr<abi.Listener>) =
  "void auk_listener_close(void *)"
pub extern fn auk_listener_port(l: raw.Ptr<abi.Listener>): i64 =
  "int64_t auk_listener_port(void *)"
pub extern fn auk_live_objects(): i64 =
  "int64_t auk_live_objects(void)"
pub extern fn auk_main_wrapper(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>, user_main: raw.Fn<(raw.Ptr<abi.Arr>) => abi.ResInt>): i32 =
  "int auk_main_wrapper(int, void *, void *)"
pub extern fn auk_make_immortal(p: raw.Ptr<()>) =
  "void auk_make_immortal(void *)"
pub extern fn auk_map_at(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>, loc: raw.Ptr<u8>): raw.Ptr<()> =
  "void *auk_map_at(void *, void *, void *)"
pub extern fn auk_map_contains(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>): bool =
  "bool auk_map_contains(void *, void *)"
pub extern fn auk_map_copy(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Map> =
  "void *auk_map_copy(void *)"
pub extern fn auk_map_eq(a: raw.Ptr<abi.Map>, b: raw.Ptr<abi.Map>): bool =
  "bool auk_map_eq(void *, void *)"
pub extern fn auk_map_find(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>): raw.Ptr<()> =
  "void *auk_map_find(void *, void *)"
pub extern fn auk_map_get_opt(m: raw.Ptr<abi.Map>, k: raw.Ptr<()>, out: raw.Ptr<()>): bool =
  "bool auk_map_get_opt(void *, void *, void *)"
pub extern fn auk_map_keys(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Arr> =
  "void *auk_map_keys(void *)"
pub extern fn auk_map_len(m: raw.Ptr<abi.Map>): i64 =
  "int64_t auk_map_len(void *)"
pub extern fn auk_map_make_unique(pm: raw.Ptr<raw.Ptr<abi.Map>>): raw.Ptr<()> =
  "void *auk_map_make_unique(void *)"
pub extern fn auk_map_new(kops: raw.Ptr<abi.ElemOps>, vops: raw.Ptr<abi.ElemOps>): raw.Ptr<abi.Map> =
  "void *auk_map_new(void *, void *)"
pub extern fn auk_map_next(m: raw.Ptr<abi.Map>, it_: raw.Ptr<i64>, k: raw.Ptr<raw.Ptr<()>>, v: raw.Ptr<raw.Ptr<()>>): bool =
  "bool auk_map_next(void *, void *, void *, void *)"
pub extern fn auk_map_remove(pm: raw.Ptr<raw.Ptr<abi.Map>>, k: raw.Ptr<()>, out: raw.Ptr<()>): bool =
  "bool auk_map_remove(void *, void *, void *)"
pub extern fn auk_map_set(pm: raw.Ptr<raw.Ptr<abi.Map>>, k: raw.Ptr<()>, v: raw.Ptr<()>) =
  "void auk_map_set(void *, void *, void *)"
pub extern fn auk_map_show(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Str> =
  "void *auk_map_show(void *)"
pub extern fn auk_map_values(m: raw.Ptr<abi.Map>): raw.Ptr<abi.Arr> =
  "void *auk_map_values(void *)"
pub extern fn auk_mod(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_mod(int64_t, int64_t, void *)"
pub extern fn auk_mul(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_mul(int64_t, int64_t, void *)"
pub extern fn auk_neg(a: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_neg(int64_t, void *)"
pub extern fn auk_net_listen(host: raw.Ptr<abi.Str>, port: i64): abi.ResListener =
  "AukRes_listener auk_net_listen(void *, int64_t)"
pub extern fn auk_net_tcp(host: raw.Ptr<abi.Str>, port: i64): abi.ResConn =
  "AukRes_conn auk_net_tcp(void *, int64_t)"
pub extern fn auk_net_tls(host: raw.Ptr<abi.Str>, port: i64): abi.ResConn =
  "AukRes_conn auk_net_tls(void *, int64_t)"
pub extern fn auk_obj_alloc(size: usize, drop: raw.Ptr<()>, copy_: raw.Ptr<()>): raw.Ptr<()> =
  "void *auk_obj_alloc(size_t, void *, void *)"
pub extern fn auk_peek(loc: raw.Ptr<u8>, src_text: raw.Ptr<u8>, shown: raw.Ptr<abi.Str>) =
  "void auk_peek(void *, void *, void *)"
pub extern fn auk_pow(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_pow(int64_t, int64_t, void *)"
pub extern fn auk_print(s: raw.Ptr<abi.Str>) =
  "void auk_print(void *)"
pub extern fn auk_print_lit(cstr: raw.Ptr<u8>) =
  "void auk_print_lit(void *)"
pub extern fn auk_proc_exit(code: i64, loc: raw.Ptr<u8>): never =
  "void auk_proc_exit(int64_t, void *)"
pub extern fn auk_proc_run(cmd: raw.Ptr<abi.Str>, args: raw.Ptr<abi.Arr>): abi.ResStr =
  "AukRes_str auk_proc_run(void *, void *)"
pub extern fn auk_rand_bytes(n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Arr> =
  "void *auk_rand_bytes(int64_t, void *)"
pub extern fn auk_rand_float(): float =
  "double auk_rand_float(void)"
pub extern fn auk_rand_int(lo: i64, hi: i64): i64 =
  "int64_t auk_rand_int(int64_t, int64_t)"
pub extern fn auk_rand_seed(seed: i64) =
  "void auk_rand_seed(int64_t)"
pub extern fn auk_refcount(p: raw.Ptr<()>): i64 =
  "int64_t auk_refcount(void *)"
pub extern fn auk_release(p: raw.Ptr<()>) =
  "void auk_release(void *)"
pub extern fn auk_requires_fail(loc: raw.Ptr<u8>, cond_text: raw.Ptr<u8>): never =
  "void auk_requires_fail(void *, void *)"
pub extern fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> =
  "void *auk_retain(void *)"
pub extern fn auk_sb_bytes(b: raw.Ptr<abi.StrBuf>, p: raw.Ptr<u8>, n: i64) =
  "void auk_sb_bytes(void *, void *, int64_t)"
pub extern fn auk_sb_char(b: raw.Ptr<abi.StrBuf>, c: u32) =
  "void auk_sb_char(void *, uint32_t)"
pub extern fn auk_sb_finish(b: raw.Ptr<abi.StrBuf>): raw.Ptr<abi.Str> =
  "void *auk_sb_finish(void *)"
pub extern fn auk_sb_int(b: raw.Ptr<abi.StrBuf>, v: i64) =
  "void auk_sb_int(void *, int64_t)"
pub extern fn auk_sb_lit(b: raw.Ptr<abi.StrBuf>, cstr: raw.Ptr<u8>) =
  "void auk_sb_lit(void *, void *)"
pub extern fn auk_sb_str(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) =
  "void auk_sb_str(void *, void *)"
pub extern fn auk_sb_str_own(b: raw.Ptr<abi.StrBuf>, s: raw.Ptr<abi.Str>) =
  "void auk_sb_str_own(void *, void *)"
pub extern fn auk_set_cleanup(f: raw.Ptr<()>) =
  "void auk_set_cleanup(void *)"
pub extern fn auk_str_append(ps: raw.Ptr<raw.Ptr<abi.Str>>, b: raw.Ptr<abi.Str>) =
  "void auk_str_append(void *, void *)"
pub extern fn auk_str_byte_len(s: raw.Ptr<abi.Str>): i64 =
  "int64_t auk_str_byte_len(void *)"
pub extern fn auk_str_bytes(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> =
  "void *auk_str_bytes(void *)"
pub extern fn auk_str_char_at(s: raw.Ptr<abi.Str>, i: i64, loc: raw.Ptr<u8>): u32 =
  "uint32_t auk_str_char_at(void *, int64_t, void *)"
pub extern fn auk_str_chars(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> =
  "void *auk_str_chars(void *)"
pub extern fn auk_str_cmp(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): i32 =
  "int auk_str_cmp(void *, void *)"
pub extern fn auk_str_concat(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_concat(void *, void *)"
pub extern fn auk_str_contains(s: raw.Ptr<abi.Str>, sub: raw.Ptr<abi.Str>): bool =
  "bool auk_str_contains(void *, void *)"
pub extern fn auk_str_cstr(s: raw.Ptr<abi.Str>): raw.Ptr<u8> =
  "void *auk_str_cstr(void *)"
pub extern fn auk_str_ends_with(s: raw.Ptr<abi.Str>, suf: raw.Ptr<abi.Str>): bool =
  "bool auk_str_ends_with(void *, void *)"
pub extern fn auk_str_eq(a: raw.Ptr<abi.Str>, b: raw.Ptr<abi.Str>): bool =
  "bool auk_str_eq(void *, void *)"
pub extern fn auk_str_eq_lit(s: raw.Ptr<abi.Str>, lit: raw.Ptr<u8>): bool =
  "bool auk_str_eq_lit(void *, void *)"
pub extern fn auk_str_find(s: raw.Ptr<abi.Str>, sub: raw.Ptr<abi.Str>): abi.OptInt =
  "AukOpt_int auk_str_find(void *, void *)"
pub extern fn auk_str_from_bool(b: bool): raw.Ptr<abi.Str> =
  "void *auk_str_from_bool(bool)"
pub extern fn auk_str_from_bytes(p: raw.Ptr<u8>, n: i64): raw.Ptr<abi.Str> =
  "void *auk_str_from_bytes(void *, int64_t)"
pub extern fn auk_str_from_char(c: u32): raw.Ptr<abi.Str> =
  "void *auk_str_from_char(uint32_t)"
pub extern fn auk_str_from_chars(chars: raw.Ptr<abi.Arr>): raw.Ptr<abi.Str> =
  "void *auk_str_from_chars(void *)"
pub extern fn auk_str_from_float(v: float): raw.Ptr<abi.Str> =
  "void *auk_str_from_float(double)"
pub extern fn auk_str_from_int(v: i64): raw.Ptr<abi.Str> =
  "void *auk_str_from_int(int64_t)"
pub extern fn auk_str_from_utf8(bytes: raw.Ptr<abi.Arr>): abi.ResStr =
  "AukRes_str auk_str_from_utf8(void *)"
pub extern fn auk_str_get(s: raw.Ptr<abi.Str>, i: i64): abi.OptChar =
  "AukOpt_char auk_str_get(void *, int64_t)"
pub extern fn auk_str_hash(s: raw.Ptr<abi.Str>): u64 =
  "uint64_t auk_str_hash(void *)"
pub extern fn auk_str_len(s: raw.Ptr<abi.Str>): i64 =
  "int64_t auk_str_len(void *)"
pub extern fn auk_str_lines(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> =
  "void *auk_str_lines(void *)"
pub extern fn auk_str_lit(cstr: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_str_lit(void *)"
pub extern fn auk_str_lower(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_lower(void *)"
pub extern fn auk_str_quote(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_quote(void *)"
pub extern fn auk_str_repeat(s: raw.Ptr<abi.Str>, n: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_str_repeat(void *, int64_t, void *)"
pub extern fn auk_str_replace(s: raw.Ptr<abi.Str>, from_: raw.Ptr<abi.Str>, to_: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_replace(void *, void *, void *)"
pub extern fn auk_str_slice(s: raw.Ptr<abi.Str>, a: i64, b: i64, loc: raw.Ptr<u8>): raw.Ptr<abi.Str> =
  "void *auk_str_slice(void *, int64_t, int64_t, void *)"
pub extern fn auk_str_split(s: raw.Ptr<abi.Str>, sep: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> =
  "void *auk_str_split(void *, void *)"
pub extern fn auk_str_split_ws(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Arr> =
  "void *auk_str_split_ws(void *)"
pub extern fn auk_str_starts_with(s: raw.Ptr<abi.Str>, pre: raw.Ptr<abi.Str>): bool =
  "bool auk_str_starts_with(void *, void *)"
pub extern fn auk_str_switch(s: raw.Ptr<abi.Str>, cases: raw.Ptr<abi.StrCase>, n: i64): i64 =
  "int64_t auk_str_switch(void *, void *, int64_t)"
pub extern fn auk_str_trim(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_trim(void *)"
pub extern fn auk_str_trim_end(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_trim_end(void *)"
pub extern fn auk_str_trim_start(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_trim_start(void *)"
pub extern fn auk_str_try_from_bytes(p: raw.Ptr<u8>, n: i64): abi.ResStr =
  "AukRes_str auk_str_try_from_bytes(void *, int64_t)"
pub extern fn auk_str_upper(s: raw.Ptr<abi.Str>): raw.Ptr<abi.Str> =
  "void *auk_str_upper(void *)"
pub extern fn auk_sub(a: i64, b: i64, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_sub(int64_t, int64_t, void *)"
pub extern fn auk_task_await(t: raw.Ptr<abi.Task>, out: raw.Ptr<()>) =
  "void auk_task_await(void *, void *)"
pub extern fn auk_task_await_all(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64, outs: raw.Ptr<()>) =
  "void auk_task_await_all(void *, int64_t, void *)"
pub extern fn auk_task_await_any(ts: raw.Ptr<raw.Ptr<abi.Task>>, n: i64, out: raw.Ptr<()>, err_: raw.Ptr<raw.Ptr<abi.Err>>, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_task_await_any(void *, int64_t, void *, void *, void *)"
pub extern fn auk_task_cancel(t: raw.Ptr<abi.Task>) =
  "void auk_task_cancel(void *)"
pub extern fn auk_task_done(t: raw.Ptr<abi.Task>): bool =
  "bool auk_task_done(void *)"
pub extern fn auk_task_spawn(fn_: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>, args: raw.Ptr<()>, args_size: usize, result_size: usize, result_ops: raw.Ptr<abi.ElemOps>, heap_: raw.Ptr<()>, args_drop: raw.Ptr<()>, hint: raw.Ptr<()>): raw.Ptr<abi.Task> =
  "void *auk_task_spawn(void *, void *, size_t, size_t, void *, void *, void *, void *)"
pub extern fn auk_test_main(argc: i32, argv: raw.Ptr<raw.Ptr<u8>>): i32 =
  "int auk_test_main(int, void *)"
pub extern fn auk_test_register(name: raw.Ptr<u8>, fn_: raw.Fn<() => raw.Ptr<abi.Err>>) =
  "void auk_test_register(void *, void *)"
pub extern fn auk_time_now(): i64 =
  "int64_t auk_time_now(void)"
pub extern fn auk_time_sleep(ms: i64) =
  "void auk_time_sleep(int64_t)"
pub extern fn auk_trace_begin(): bool =
  "bool auk_trace_begin(void)"
pub extern fn auk_trace_call(fn_: raw.Ptr<u8>, loc: raw.Ptr<u8>, n: i32, args: raw.Ptr<raw.Ptr<abi.Str>>) =
  "void auk_trace_call(void *, void *, int, void *)"
pub extern fn auk_trace_exit(): bool =
  "bool auk_trace_exit(void)"
pub extern fn auk_trace_init(tests: bool) =
  "void auk_trace_init(bool)"
pub extern fn auk_trace_ret(fn_: raw.Ptr<u8>, shown: raw.Ptr<abi.Str>) =
  "void auk_trace_ret(void *, void *)"
pub extern fn auk_unwrap_err(loc: raw.Ptr<u8>, e: raw.Ptr<abi.Err>): never =
  "void auk_unwrap_err(void *, void *)"
pub extern fn auk_unwrap_none(loc: raw.Ptr<u8>): never =
  "void auk_unwrap_none(void *)"
pub extern fn auk_utf8_valid(p: raw.Ptr<u8>, n: i64, chars_out: raw.Ptr<i64>, ascii_out: raw.Ptr<bool>): bool =
  "bool auk_utf8_valid(void *, int64_t, void *, void *)"
pub extern fn auk_value_as_float(v: abi.Value, loc: raw.Ptr<u8>): float =
  "double auk_value_as_float(AukValue, void *)"
pub extern fn auk_value_as_int(v: abi.Value, loc: raw.Ptr<u8>): i64 =
  "int64_t auk_value_as_int(AukValue, void *)"
pub extern fn auk_value_as_map(v: abi.Value, loc: raw.Ptr<u8>): raw.Ptr<abi.Map> =
  "void *auk_value_as_map(AukValue, void *)"
pub extern fn auk_value_bool(b: bool): abi.Value =
  "AukValue auk_value_bool(bool)"
pub extern fn auk_value_eq(a: abi.Value, b: abi.Value): bool =
  "bool auk_value_eq(AukValue, AukValue)"
pub extern fn auk_value_float(f: float): abi.Value =
  "AukValue auk_value_float(double)"
pub extern fn auk_value_int(i: i64): abi.Value =
  "AukValue auk_value_int(int64_t)"
pub extern fn auk_value_list(xs: raw.Ptr<abi.Arr>): abi.Value =
  "AukValue auk_value_list(void *)"
pub extern fn auk_value_list_new(): raw.Ptr<abi.Arr> =
  "void *auk_value_list_new(void)"
pub extern fn auk_value_map(m: raw.Ptr<abi.Map>): abi.Value =
  "AukValue auk_value_map(void *)"
pub extern fn auk_value_map_new(): raw.Ptr<abi.Map> =
  "void *auk_value_map_new(void)"
pub extern fn auk_value_map_put(pm: raw.Ptr<raw.Ptr<abi.Map>>, key: raw.Ptr<u8>, val: abi.Value) =
  "void auk_value_map_put(void *, void *, AukValue)"
pub extern fn auk_value_null(): abi.Value =
  "AukValue auk_value_null(void)"
pub extern fn auk_value_release(v: abi.Value) =
  "void auk_value_release(AukValue)"
pub extern fn auk_value_show(v: abi.Value): raw.Ptr<abi.Str> =
  "void *auk_value_show(AukValue)"
pub extern fn auk_value_str(s: raw.Ptr<abi.Str>): abi.Value =
  "AukValue auk_value_str(void *)"
pub extern fn auk_value_tag_name(t: u32): raw.Ptr<u8> =
  "void *auk_value_tag_name(uint32_t)"
pub extern fn auk_wadd(a: i64, b: i64): i64 =
  "int64_t auk_wadd(int64_t, int64_t)"
pub extern fn auk_wmul(a: i64, b: i64): i64 =
  "int64_t auk_wmul(int64_t, int64_t)"
pub extern fn auk_wsub(a: i64, b: i64): i64 =
  "int64_t auk_wsub(int64_t, int64_t)"

// internal entry points (not in auk_rt.h)
pub extern fn auk__err_bytes(msg: raw.Ptr<u8>, n: usize): raw.Ptr<abi.Err> =
  "void *auk__err_bytes(const char *, size_t)"
pub extern fn auk__heap_sweep(h: raw.Ptr<()>) = "void auk__heap_sweep(void *)"
pub extern fn auk__trace_flush() = "void auk__trace_flush(void)"

// ---- the runtime's data ----------------------------------------------------------------------

extern var auk_ops_int: abi.ElemOps = "auk_ops_int"
extern var auk_ops_float: abi.ElemOps = "auk_ops_float"
extern var auk_ops_bool: abi.ElemOps = "auk_ops_bool"
extern var auk_ops_char: abi.ElemOps = "auk_ops_char"
extern var auk_ops_str: abi.ElemOps = "auk_ops_str"
extern var auk_ops_arr: abi.ElemOps = "auk_ops_arr"
extern var auk_ops_closure: abi.ElemOps = "auk_ops_closure"
extern var auk_cancel_pending: i64 = "auk_cancel_pending"
extern var auk_dbg_armed: i64 = "auk_dbg_armed"

/// &auk_ops_int, …
pub raw let OPS_INT: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_int)
pub raw let OPS_FLOAT: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_float)
pub raw let OPS_BOOL: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_bool)
pub raw let OPS_CHAR: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_char)
pub raw let OPS_STR: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_str)
pub raw let OPS_ARR: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_arr)
pub raw let OPS_CLOSURE: raw.Ptr<abi.ElemOps> = raw.addr_of(&auk_ops_closure)
/// &auk_cancel_pending, &auk_dbg_armed (C's `_Atomic int64_t`s: read them with raw.atomic_load)
pub raw let CANCEL_PENDING: raw.Ptr<i64> = raw.addr_of(&auk_cancel_pending)
pub raw let DBG_ARMED: raw.Ptr<i64> = raw.addr_of(&auk_dbg_armed)

// ---- the C library ---------------------------------------------------------------------------

pub extern fn printf(fmt: raw.Ptr<u8>, ...): i32 = "int printf(const char *, ...)"
pub extern fn fprintf(f: raw.Ptr<()>, fmt: raw.Ptr<u8>, ...): i32 = "int fprintf(FILE *, const char *, ...)"
pub extern fn snprintf(buf: raw.Ptr<u8>, n: usize, fmt: raw.Ptr<u8>, ...): i32 =
  "int snprintf(char *, size_t, const char *, ...)"
pub extern fn fflush(f: raw.Ptr<()>): i32 = "int fflush(FILE *)"
pub extern fn fputs(s: raw.Ptr<u8>, f: raw.Ptr<()>): i32 = "int fputs(const char *, FILE *)"
pub extern fn fopen(path: raw.Ptr<u8>, mode: raw.Ptr<u8>): raw.Ptr<()> = "FILE *fopen(const char *, const char *)"
pub extern fn fclose(f: raw.Ptr<()>): i32 = "int fclose(FILE *)"
pub extern fn fwrite(p: raw.Ptr<()>, size: usize, n: usize, f: raw.Ptr<()>): usize =
  "size_t fwrite(const void *, size_t, size_t, FILE *)"
pub extern fn fgets(buf: raw.Ptr<u8>, n: i32, f: raw.Ptr<()>): raw.Ptr<u8> = "char *fgets(char *, int, FILE *)"
pub extern fn clearerr(f: raw.Ptr<()>) = "void clearerr(FILE *)"
pub extern fn strlen(s: raw.Ptr<u8>): usize = "size_t strlen(const char *)"
pub extern fn strcmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>): i32 = "int strcmp(const char *, const char *)"
pub extern fn strncmp(a: raw.Ptr<u8>, b: raw.Ptr<u8>, n: usize): i32 = "int strncmp(const char *, const char *, size_t)"
pub extern fn strstr(s: raw.Ptr<u8>, sub: raw.Ptr<u8>): raw.Ptr<u8> = "char *strstr(const char *, const char *)"
pub extern fn strchr(s: raw.Ptr<u8>, c: i32): raw.Ptr<u8> = "char *strchr(const char *, int)"
pub extern fn atoll(s: raw.Ptr<u8>): i64 = "long long atoll(const char *)"
pub extern fn getenv(name: raw.Ptr<u8>): raw.Ptr<u8> = "char *getenv(const char *)"
pub extern fn setenv(name: raw.Ptr<u8>, val: raw.Ptr<u8>, over: i32): i32 = "int setenv(const char *, const char *, int)"
pub extern fn unsetenv(name: raw.Ptr<u8>): i32 = "int unsetenv(const char *)"
pub extern fn tan(x: float): float = "double tan(double)"
pub extern fn dlsym(h: raw.Ptr<()>, name: raw.Ptr<u8>): raw.Ptr<()> = "void *dlsym(void *, const char *)"

// files and processes
pub extern fn c_write(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t write(int, const void *, size_t)"
pub extern fn c_read(fd: i32, p: raw.Ptr<()>, n: usize): i64 = "ssize_t read(int, void *, size_t)"
pub extern fn close(fd: i32): i32 = "int close(int)"
pub extern fn dup2(fd: i32, to: i32): i32 = "int dup2(int, int)"
pub extern fn pipe(fds: raw.Ptr<i32>): i32 = "int pipe(int *)"
pub extern fn fork(): i32 = "int fork(void)"
pub extern fn waitpid(pid: i32, status: raw.Ptr<i32>, options: i32): i32 = "int waitpid(int, int *, int)"
pub extern fn c_exit(code: i32): never = "void _exit(int)"
pub extern fn mkdtemp(tmpl: raw.Ptr<u8>): raw.Ptr<u8> = "char *mkdtemp(char *)"
pub extern fn stat(path: raw.Ptr<u8>, st: raw.Ptr<cfacts.Stat>): i32 = "int stat(const char *, void *)"
pub extern fn lstat(path: raw.Ptr<u8>, st: raw.Ptr<cfacts.Stat>): i32 = "int lstat(const char *, void *)"
pub extern fn opendir(path: raw.Ptr<u8>): raw.Ptr<()> = "void *opendir(const char *)"
pub extern fn readdir(d: raw.Ptr<()>): raw.Ptr<cfacts.Dirent> = "void *readdir(void *)"
pub extern fn closedir(d: raw.Ptr<()>): i32 = "int closedir(void *)"
pub extern fn rmdir(path: raw.Ptr<u8>): i32 = "int rmdir(const char *)"
pub extern fn unlink(path: raw.Ptr<u8>): i32 = "int unlink(const char *)"

// sockets and threads
pub extern fn socket(domain: i32, kind: i32, proto: i32): i32 = "int socket(int, int, int)"
pub extern fn bind(fd: i32, addr: raw.Ptr<()>, len: u32): i32 = "int bind(int, const void *, unsigned)"
pub extern fn listen(fd: i32, backlog: i32): i32 = "int listen(int, int)"
pub extern fn accept(fd: i32, addr: raw.Ptr<()>, len: raw.Ptr<u32>): i32 = "int accept(int, void *, unsigned *)"
pub extern fn connect(fd: i32, addr: raw.Ptr<()>, len: u32): i32 = "int connect(int, const void *, unsigned)"
pub extern fn getsockname(fd: i32, addr: raw.Ptr<()>, len: raw.Ptr<u32>): i32 = "int getsockname(int, void *, unsigned *)"
pub extern fn getsockopt(fd: i32, level: i32, name: i32, val: raw.Ptr<()>, len: raw.Ptr<u32>): i32 =
  "int getsockopt(int, int, int, void *, unsigned *)"
pub extern fn fcntl(fd: i32, cmd: i32, ...): i32 = "int fcntl(int, int, ...)"
pub extern fn poll(fds: raw.Ptr<cfacts.Pollfd>, n: u64, ms: i32): i32 = "int poll(void *, unsigned long, int)"
pub extern fn getaddrinfo(host: raw.Ptr<u8>, port: raw.Ptr<u8>, hints: raw.Ptr<cfacts.Addrinfo>, res: raw.Ptr<raw.Ptr<cfacts.Addrinfo>>): i32 =
  "int getaddrinfo(const char *, const char *, const void *, void *)"
pub extern fn freeaddrinfo(ai: raw.Ptr<cfacts.Addrinfo>) = "void freeaddrinfo(void *)"
pub extern fn pthread_create(th: raw.Ptr<cfacts.PthreadT>, attr: raw.Ptr<()>, start: raw.Fn<(raw.Ptr<()>) => raw.Ptr<()>>, arg: raw.Ptr<()>): i32 =
  "int pthread_create(void *, const void *, void *, void *)"
pub extern fn pthread_join(th: u64, out: raw.Ptr<raw.Ptr<()>>): i32 = "int pthread_join(uint64_t, void **)"
