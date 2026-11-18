/* The Auk runtime: shared types and entry points.
 *
 * Every function marked AUK_API is called by generated code (the JIT resolves it in the
 * compiler's own process, `auk build` links libauk_rt.a); build.rs reads those lines to make
 * the JIT's symbol table. The struct layouts are fixed: `src/mir/layout.rs` computes the same
 * ones, and `src/mir/llvm/intrin.rs` inlines field accesses by offset.
 *
 * Ownership conventions (see also runtime/src/lib.rs while the port is under way):
 * 1. Heap objects start with an AukHeader and are reference counted; a new object has rc 1.
 * 2. Arguments are borrowed, returned objects are owned (+1), results inside AukOpt_* and
 *    AukRes_* too.
 * 3. Elements passed into a container are borrowed (it retains its own copy); `void *out`
 *    parameters receive owned values; `*_at`/`*_find` return borrowed pointers.
 * 4. Mutating functions take `AukArr **`/`AukMap **` and copy first when shared.
 * 5. NULL means "" wherever an AukStr * is read; retain/release accept NULL.
 * 6. `loc` parameters are "file:line:col" strings for panic messages.
 *
 * The C is written to translate to Auk later (docs/self-host-plan.md, Phase 7): plain
 * functions and structs, no macro-generated code, no varargs, no bit-fields. */
#ifndef AUK_RT_H
#define AUK_RT_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Marks an entry point generated code calls (read by build.rs; expands to nothing). */
#define AUK_API

/* ---- object kinds ------------------------------------------------------------------------ */

enum {
    AUK_K_STR = 1,
    AUK_K_ARR = 2,
    AUK_K_MAP = 3,
    AUK_K_ERR = 4,
    AUK_K_OBJ = 5,
    AUK_K_TASK = 6,
    AUK_K_CONN = 7,
    AUK_K_LISTENER = 8,
    AUK_K_CHAN = 9,
    AUK_K_FRAME = 10,
};

/* AukHeader.flags: the object has a heap Link prefix (heap.c). */
enum { AUK_TRACKED = 1 };

/* Every heap object begins with this (16 bytes). rc < 0 marks an immortal object. */
typedef struct AukHeader {
    _Atomic int64_t rc;
    uint32_t kind;
    uint32_t flags;
} AukHeader;

typedef uint8_t AukUnit;

typedef struct AukStr AukStr;
typedef struct AukArr AukArr;
typedef struct AukMap AukMap;
typedef struct AukErr AukErr;
typedef struct AukObj AukObj;
typedef struct AukTask AukTask;
typedef struct AukChan AukChan;
typedef struct AukConn AukConn;
typedef struct AukListener AukListener;

/* ---- element ops ------------------------------------------------------------------------- */

typedef void (*AukRetainFn)(void *p);
typedef bool (*AukEqFn)(const void *a, const void *b);
typedef int (*AukCmpFn)(const void *a, const void *b);
typedef uint64_t (*AukHashFn)(const void *a);
typedef AukStr *(*AukShowFn)(const void *a);
/* Write a deep copy of *src (owned, in the current heap) to dst; NULL for plain data. */
typedef void (*AukCopyFn)(const void *src, void *dst);
typedef AukObj *(*AukObjCopyFn)(const AukObj *o);
typedef void (*AukDropFn)(AukObj *o);

typedef struct AukElemOps {
    size_t size;
    AukRetainFn retain;
    AukRetainFn release;
    AukEqFn eq;
    AukCmpFn cmp;
    AukHashFn hash;
    AukShowFn show;
    AukCopyFn copy;
} AukElemOps;

/* ---- heap objects ------------------------------------------------------------------------ */

/* Immutable UTF-8 string; data is NUL-terminated (data[len_bytes] == 0). */
struct AukStr {
    AukHeader h;
    int64_t len_bytes;
    int64_t len_chars;
    bool is_ascii;
    uint8_t data[];
};

/* An array. A slice view has base != NULL. */
struct AukArr {
    AukHeader h;
    const AukElemOps *ops;
    int64_t len;
    int64_t cap;
    uint8_t *data;
    AukArr *base;
};

/* Insertion-ordered hash map: an index table over an entries array (map.rs). */
struct AukMap {
    AukHeader h;
    const AukElemOps *kops;
    const AukElemOps *vops;
    int64_t len;
    int64_t n;
    int64_t cap;
    uint8_t *entries;
    int64_t voff;
    int64_t stride;
    uint64_t *hashes;
    bool *dead;
    uint64_t *index;
    int64_t icap;
};

typedef struct AukErrPayload {
    uint32_t type_id;
    void *data;
    const AukElemOps *ops;
} AukErrPayload;

struct AukErr {
    AukHeader h;
    AukStr *msg;
    int64_t code;
    AukErr *cause;
    AukErrPayload payload;
};

/* Generic heap object with a destructor (closure envs, boxes). */
struct AukObj {
    AukHeader h;
    AukDropFn drop;
    AukObjCopyFn copy;
};

typedef struct AukClosure {
    void *fn;
    AukObj *env;
} AukClosure;

enum {
    AUK_V_NULL = 0,
    AUK_V_BOOL = 1,
    AUK_V_INT = 2,
    AUK_V_FLOAT = 3,
    AUK_V_STR = 4,
    AUK_V_LIST = 5,
    AUK_V_MAP = 6,
};

/* The core `Value` enum. */
typedef struct AukValue {
    uint32_t tag;
    union {
        bool b;
        int64_t i;
        double f;
        AukStr *s;
        AukArr *list;
        AukMap *map;
    } u;
} AukValue;

/* Optionals (`T?`: { bool some; T val; }) and results (`T!`: { bool ok; T val; AukErr *err; }). */
typedef struct AukOpt_int {
    bool some;
    int64_t val;
} AukOpt_int;
typedef struct AukOpt_float {
    bool some;
    double val;
} AukOpt_float;
typedef struct AukOpt_bool {
    bool some;
    bool val;
} AukOpt_bool;
typedef struct AukOpt_char {
    bool some;
    uint32_t val;
} AukOpt_char;
typedef struct AukOpt_str {
    bool some;
    AukStr *val;
} AukOpt_str;
typedef struct AukOpt_arr {
    bool some;
    AukArr *val;
} AukOpt_arr;
typedef struct AukOpt_value {
    bool some;
    AukValue val;
} AukOpt_value;
typedef struct AukRes_unit {
    bool ok;
    AukUnit val;
    AukErr *err;
} AukRes_unit;
typedef struct AukRes_int {
    bool ok;
    int64_t val;
    AukErr *err;
} AukRes_int;
typedef struct AukRes_float {
    bool ok;
    double val;
    AukErr *err;
} AukRes_float;
typedef struct AukRes_str {
    bool ok;
    AukStr *val;
    AukErr *err;
} AukRes_str;
typedef struct AukRes_arr {
    bool ok;
    AukArr *val;
    AukErr *err;
} AukRes_arr;
typedef struct AukRes_conn {
    bool ok;
    AukConn *val;
    AukErr *err;
} AukRes_conn;
typedef struct AukRes_listener {
    bool ok;
    AukListener *val;
    AukErr *err;
} AukRes_listener;
typedef struct AukRes_value {
    bool ok;
    AukValue val;
    AukErr *err;
} AukRes_value;

/* Map entry i's key and value (map.rs). */
static inline uint8_t *auk__map_key(const AukMap *m, int64_t i) {
    return m->entries + i * m->stride;
}
static inline uint8_t *auk__map_val(const AukMap *m, int64_t i) {
    return m->entries + i * m->stride + m->voff;
}

/* A TCP connection (tls: the TLS session over fd, NULL for plain TCP). */
struct AukConn {
    AukHeader h;
    int fd;
    void *tls;
};

struct AukListener {
    AukHeader h;
    int fd;
    int64_t port;
};

/* Growable string builder; zero-initialized by its owner. Up to AUK_SB_SMALL bytes stay in
 * `small` (buf NULL, cap 0). No pointer into itself, so it may be moved. */
enum { AUK_SB_SMALL = 40 };
typedef struct AukStrBuf {
    uint8_t *buf;
    int64_t len;
    int64_t cap;
    uint8_t small[AUK_SB_SMALL];
} AukStrBuf;

/* ---- rc.c: allocation, refcounts, panics, arithmetic, hashing, scalar ops ---------------- */

void *auk__xmalloc(size_t n);
void *auk__xcalloc(size_t n, size_t size);
void *auk__xrealloc(void *p, size_t n);
void *auk__alloc(size_t size, uint32_t kind);
void auk__free_obj(void *p);
void auk__make_immortal(void *p);
void auk__free_now(void *p);

AUK_API int64_t auk_live_objects(void);
AUK_API void auk_make_immortal(void *p);
AUK_API void auk_set_cleanup(void (*f)(void));
AUK_API int64_t auk_leak_check(void);
AUK_API void *auk_retain(void *p);
AUK_API void auk_release(void *p);
AUK_API void auk__free_last(void *p);
AUK_API int64_t auk_refcount(const void *p);

/* Panic with a message of n bytes: print `panic: <msg>\n  at <loc>` and exit 101, or jump to
 * this thread's recovery point (catch.c). */
_Noreturn void auk__panic(const char *loc, const char *msg, size_t n);
/* Panic with `<a><b><c>` (any may be NULL): messages built without varargs. */
_Noreturn void auk__panic3(const char *loc, const char *a, const char *b, const char *c);

AUK_API _Noreturn void auk_panic_str(const char *loc, const char *msg);
AUK_API _Noreturn void auk_panic_overflow(const char *loc, const char *op);
AUK_API _Noreturn void auk_panic_div_zero(const char *loc);
AUK_API _Noreturn void auk_unwrap_none(const char *loc);
AUK_API _Noreturn void auk_unwrap_err(const char *loc, AukErr *e);

AUK_API int64_t auk_add(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_sub(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_mul(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_div(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_mod(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_neg(int64_t a, const char *loc);
AUK_API int64_t auk_wadd(int64_t a, int64_t b);
AUK_API int64_t auk_wsub(int64_t a, int64_t b);
AUK_API int64_t auk_wmul(int64_t a, int64_t b);
AUK_API int64_t auk_shl(int64_t a, int64_t n, const char *loc);
AUK_API int64_t auk_shr(int64_t a, int64_t n, const char *loc);
AUK_API int auk_int_cmp(int64_t a, int64_t b);
AUK_API int64_t auk_pow(int64_t a, int64_t b, const char *loc);
AUK_API int64_t auk_int_abs(int64_t a, const char *loc);
AUK_API double auk_fpow(double a, double b);
AUK_API double auk_fmod(double a, double b);
AUK_API double auk_fsqrt(double a);
AUK_API double auk_fabs(double a);
AUK_API double auk_ffloor(double a);
AUK_API double auk_fceil(double a);
AUK_API double auk_fround(double a);
AUK_API double auk_fsin(double a);
AUK_API double auk_fcos(double a);
AUK_API double auk_ftan(double a);
AUK_API double auk_fasin(double a);
AUK_API double auk_facos(double a);
AUK_API double auk_fatan(double a);
AUK_API double auk_fexp(double a);
AUK_API double auk_fln(double a);
AUK_API double auk_flog10(double a);
AUK_API double auk_flog2(double a);
AUK_API double auk_fatan2(double y, double x);
AUK_API int64_t auk_fbits(double a);
AUK_API double auk_ffrom_bits(int64_t n);
AUK_API int64_t auk_fbits32(double a);
AUK_API double auk_ffrom_bits32(int64_t n);
AUK_API int64_t auk_float_to_int(double x, const char *loc);
AUK_API int auk_float_cmp(double a, double b);

AUK_API uint64_t auk_hash_bytes(const void *p, size_t n);
AUK_API uint64_t auk_hash_int(int64_t x);
AUK_API uint64_t auk_hash_combine(uint64_t h, uint64_t x);

void auk__ptr_retain(void *p);
void auk__ptr_release(void *p);

AUK_API extern const AukElemOps auk_ops_int;
AUK_API extern const AukElemOps auk_ops_float;
AUK_API extern const AukElemOps auk_ops_bool;
AUK_API extern const AukElemOps auk_ops_char;
AUK_API extern const AukElemOps auk_ops_unit;
AUK_API extern const AukElemOps auk_ops_str;
AUK_API extern const AukElemOps auk_ops_arr;
AUK_API extern const AukElemOps auk_ops_map;
AUK_API extern const AukElemOps auk_ops_err;
AUK_API extern const AukElemOps auk_ops_obj;
AUK_API extern const AukElemOps auk_ops_task;
AUK_API extern const AukElemOps auk_ops_closure;

AUK_API void auk_closure_retain(AukClosure c);
AUK_API void auk_closure_release(AukClosure c);

/* Panic at "runtime" with a fixed message (an internal error, not the program's). */
_Noreturn void auk__panic_rt(const char *msg);

/* A scratch element buffer: on the stack when it fits, else malloc'd. */
typedef struct AukTmp {
    uint8_t stack[256];
    uint8_t *heap;
} AukTmp;
uint8_t *auk__tmp_get(AukTmp *t, size_t size);
void auk__tmp_done(AukTmp *t);

/* ---- heap.c: per-task heaps -------------------------------------------------------------- */

typedef struct AukHeap AukHeap;

/* Is an object of this kind a handle (never tracked, shared by reference count)? */
static inline bool auk__is_handle(uint32_t kind) {
    return kind >= AUK_K_TASK && kind <= AUK_K_FRAME; /* 6..=10 */
}
void auk__note_handle(const void *p, int64_t delta);
AukHeap *auk__heap_new(void);
AukHeap *auk__heap_current(void);
AukHeap *auk__heap_switch(AukHeap *h);
AukHeader *auk__heap_alloc(size_t size, uint32_t kind);
void auk__heap_free(AukHeader *h);
void auk__heap_sweep(AukHeap *heap);
AUK_API void *auk_heap_switch(void *h);
AUK_API void *auk_heap_new(void);

/* ---- catch.c: recovery points ------------------------------------------------------------ */

typedef void (*AukThunk)(void *env, void *out);

/* A recovered panic: its message and where it happened (malloc'd strings). */
typedef struct AukPanic {
    char *msg;
    char *loc;
} AukPanic;

/* Run f(env, out); 0 when it finished, 1 when a panic jumped back here. */
int auk__catch_run(AukThunk f, void *env, void *out);
int auk__catch_active(void);
/* Record a panic (copies msg and loc) and jump to the innermost recovery point. */
_Noreturn void auk__catch_throw(const char *loc, const char *msg, size_t n);
/* Take the recorded panic: malloc'd strings the caller frees (NULL if none). */
void auk__catch_take(char **msg, char **loc);
AukPanic *auk__catch_call(AukThunk f, void *env, void *out);
void auk__panic_free(AukPanic *p);
AukErr *auk__panic_err(const AukPanic *p);
AUK_API AukErr *auk_catch(AukThunk f, void *env, void *out);

/* ---- err.c ------------------------------------------------------------------------------- */

AUK_API AukErr *auk_err_new(const AukStr *msg);
AUK_API AukErr *auk_err_new_cstr(const char *msg);
AUK_API AukErr *auk_err_wrap(const AukStr *msg, AukErr *cause);
AUK_API AukErr *auk_err_typed(uint32_t type_id, const void *value, const AukElemOps *ops, const AukStr *msg);
AUK_API const void *auk_err_payload(const AukErr *e, uint32_t type_id);
AUK_API AukStr *auk_err_show(const AukErr *e);
/* A new error with the n bytes at msg (repaired to UTF-8). */
AukErr *auk__err_bytes(const char *msg, size_t n);
void auk__err_free(AukErr *e);
/* "<what> <subject>: <strerror>" (or "<what>: <strerror>"), code errno. */
AukErr *auk__err_errno(const char *what, const AukStr *subject, int err);

/* ---- copy.c: deep copies across task boundaries ---------------------------------------- */

AUK_API void *auk_obj_alloc(size_t size, AukDropFn drop, AukObjCopyFn copy);
AUK_API AukObj *auk_obj_copy(AukObj *o);
AUK_API AukStr *auk_str_copy(AukStr *s);
AUK_API AukArr *auk_arr_copy_deep(AukArr *a);
AUK_API AukMap *auk_map_copy_deep(AukMap *m);
AUK_API AukErr *auk_err_copy_deep(AukErr *e);
AUK_API AukValue auk_value_copy(AukValue v);
void auk__copy_elem(const AukElemOps *ops, const void *src, void *dst);
void auk__str_copy_elem(const void *src, void *dst);
void auk__arr_copy_elem(const void *src, void *dst);
void auk__map_copy_elem(const void *src, void *dst);
void auk__err_copy_elem(const void *src, void *dst);
void auk__obj_copy_elem(const void *src, void *dst);
void auk__handle_copy_elem(const void *src, void *dst);
void auk__closure_copy_elem(const void *src, void *dst);
void auk__value_copy_elem(const void *src, void *dst);

/* ---- value.c ----------------------------------------------------------------------------- */

AUK_API AukValue auk_value_null(void);
AUK_API AukValue auk_value_bool(bool b);
AUK_API AukValue auk_value_int(int64_t i);
AUK_API AukValue auk_value_float(double f);
AUK_API AukValue auk_value_str(AukStr *s);
AUK_API AukValue auk_value_list(AukArr *xs);
AUK_API AukValue auk_value_map(AukMap *m);
AUK_API AukArr *auk_value_list_new(void);
AUK_API AukMap *auk_value_map_new(void);
AUK_API void auk_value_map_put(AukMap **pm, const char *key, AukValue val);
AUK_API void auk_value_retain(AukValue v);
AUK_API void auk_value_release(AukValue v);
AUK_API const char *auk_value_tag_name(uint32_t t);
AUK_API bool auk_value_as_bool(AukValue v, const char *loc);
AUK_API int64_t auk_value_as_int(AukValue v, const char *loc);
AUK_API double auk_value_as_float(AukValue v, const char *loc);
AUK_API AukStr *auk_value_as_str(AukValue v, const char *loc);
AUK_API AukArr *auk_value_as_list(AukValue v, const char *loc);
AUK_API AukMap *auk_value_as_map(AukValue v, const char *loc);
AUK_API bool auk_value_eq(AukValue a, AukValue b);
AUK_API AukStr *auk_value_show(AukValue v);
AUK_API extern const AukElemOps auk_ops_value;

/* ---- trace.c: execution traces ---------------------------------------------------------- */

AUK_API extern _Atomic bool auk_trace_live;
AUK_API const char **auk__trace_site_slot(void);
AUK_API void auk_trace_init(bool tests);
bool auk__trace_tail_mode(void);
const char *auk__trace_dir(void);
void auk__trace_test_begin(const char *name, const char *tail_path);
void auk__trace_test_end(const char *name, bool ok, const char *tail_path);
void auk__trace_flush(void);
AUK_API bool auk_trace_begin(void);
AUK_API void auk_trace_call(const char *fn, const char *loc, int n, AukStr **args);
AUK_API bool auk_trace_exit(void);
AUK_API void auk_trace_ret(const char *fn, AukStr *shown);
AUK_API void auk_trace_err(const char *fn, const AukErr *e);
void auk__trace_peek(const char *loc, const char *src_text, const AukStr *shown);
void auk__trace_on_panic(const char *loc, const char *msg, size_t n, bool caught);
void auk__trace_save(int64_t *depth, int *mute);
void auk__trace_restore(int64_t depth, int mute);

/* ---- str.c: strings, the builder, parsing and formatting ---------------------------------- */

bool auk__dbg_busy(void);
bool auk__dbg_set_busy(bool b);
int64_t auk__show_left(void);
void auk__set_show_left(int64_t v);
bool auk__show_exhausted(void);
bool auk__show_take(int64_t n);

AUK_API int64_t auk_str_len(const AukStr *s);
AUK_API int64_t auk_str_byte_len(const AukStr *s);
AUK_API const char *auk_str_cstr(const AukStr *s);
AUK_API bool auk_utf8_valid(const char *p, int64_t n, int64_t *chars_out, bool *ascii_out);
AUK_API int auk_utf8_encode(uint32_t c, char *buf);
void auk__sb_put(AukStrBuf *b, const void *p, int64_t n);
void auk__sb_put_cstr(AukStrBuf *b, const char *s);
AUK_API void auk_sb_bytes(AukStrBuf *b, const char *p, int64_t n);
AUK_API void auk_sb_lit(AukStrBuf *b, const char *cstr);
AUK_API void auk_sb_str(AukStrBuf *b, const AukStr *s);
AUK_API void auk_sb_str_own(AukStrBuf *b, AukStr *s);
AUK_API void auk_sb_char(AukStrBuf *b, uint32_t c);
AUK_API void auk_sb_int(AukStrBuf *b, int64_t v);
AUK_API AukStr *auk_sb_finish(AukStrBuf *b);
AUK_API void auk_sb_free(AukStrBuf *b);
_Noreturn void auk__panic_sb(const char *loc, AukStrBuf *b);
AukErr *auk__err_sb(AukStrBuf *b);
AukStr *auk__str_raw(const char *p, int64_t n, int64_t chars, bool ascii);
AukStr *auk__str_new(const char *p, int64_t n);
AUK_API AukStr *auk_str_from_bytes(const char *p, int64_t n);
AUK_API AukStr *auk_str_lit(const char *cstr);
AUK_API AukRes_str auk_str_try_from_bytes(const char *p, int64_t n);
AUK_API AukRes_str auk_str_from_utf8(AukArr *bytes);
int64_t auk__str_byte_offset(const AukStr *s, int64_t i);
AUK_API uint32_t auk_str_char_at(const AukStr *s, int64_t i, const char *loc);
AUK_API AukOpt_char auk_str_get(const AukStr *s, int64_t i);
AUK_API AukStr *auk_str_slice(const AukStr *s, int64_t a, int64_t b, const char *loc);
AUK_API AukStr *auk_str_concat(const AukStr *a, const AukStr *b);
AUK_API bool auk_str_eq(const AukStr *a, const AukStr *b);
AUK_API bool auk_str_eq_lit(const AukStr *s, const char *lit);
AUK_API int auk_str_cmp(const AukStr *a, const AukStr *b);
AUK_API uint64_t auk_str_hash(const AukStr *s);
void auk__str_free(AukStr *s);
AUK_API AukArr *auk_str_split_ws(const AukStr *s);
AUK_API AukArr *auk_str_split(const AukStr *s, const AukStr *sep);
AUK_API AukStr *auk_str_trim_start(const AukStr *s);
AUK_API AukStr *auk_str_trim_end(const AukStr *s);
AUK_API AukStr *auk_str_trim(const AukStr *s);
AUK_API AukArr *auk_str_lines(const AukStr *s);
AUK_API bool auk_str_starts_with(const AukStr *s, const AukStr *pre);
AUK_API bool auk_str_ends_with(const AukStr *s, const AukStr *suf);
AUK_API bool auk_str_contains(const AukStr *s, const AukStr *sub);
AUK_API AukOpt_int auk_str_find(const AukStr *s, const AukStr *sub);
AUK_API AukStr *auk_str_replace(const AukStr *s, const AukStr *from, const AukStr *to);
AUK_API AukStr *auk_str_upper(const AukStr *s);
AUK_API AukStr *auk_str_lower(const AukStr *s);
AUK_API AukStr *auk_str_repeat(const AukStr *s, int64_t n, const char *loc);
AUK_API AukArr *auk_str_chars(const AukStr *s);
AUK_API AukArr *auk_str_bytes(const AukStr *s);
AUK_API AukStr *auk_str_from_chars(AukArr *chars);
AUK_API AukRes_int auk_int_parse(const AukStr *s);
AUK_API AukRes_float auk_float_parse(const AukStr *s);
AUK_API bool auk_char_is_digit(uint32_t c);
AUK_API bool auk_char_is_alpha(uint32_t c);
AUK_API bool auk_char_is_space(uint32_t c);
AUK_API uint32_t auk_char_upper(uint32_t c);
AUK_API uint32_t auk_char_lower(uint32_t c);
AUK_API AukOpt_char auk_char_from_int(int64_t n);
AUK_API AukStr *auk_str_from_int(int64_t v);
void auk__fmt_float_shortest(double v, char *out, size_t outn);
AUK_API AukStr *auk_str_from_float(double v);
AUK_API AukStr *auk_str_from_char(uint32_t c);
AUK_API AukStr *auk_str_from_bool(bool b);
AUK_API AukStr *auk_str_quote(const AukStr *s);
AUK_API AukStr *auk_char_quote(uint32_t c);
AUK_API AukStr *auk_fmt_int(int64_t v, const char *spec);
AUK_API AukStr *auk_fmt_float(double v, const char *spec);
AUK_API AukStr *auk_fmt_str(const AukStr *s, const char *spec);
AUK_API AukStr *auk_fmt_char(uint32_t c, const char *spec);
AUK_API AukStr *auk_fmt_bool(bool v, const char *spec);

/* ---- arr.c: arrays ------------------------------------------------------------------------ */

AUK_API int64_t auk_arr_len(const AukArr *a);
AUK_API const void *auk_arr_data(const AukArr *a);
AUK_API AukArr *auk_arr_new(const AukElemOps *ops, int64_t cap);
AUK_API AukArr *auk_arr_from(const AukElemOps *ops, const void *elems, int64_t n);
void auk__arr_free(AukArr *a);
AUK_API void *auk_arr_at(const AukArr *a, int64_t i, const char *loc);
AUK_API bool auk_arr_get_opt(const AukArr *a, int64_t i, void *out);
AUK_API void *auk_arr_make_unique(AukArr **pa);
AUK_API void auk_arr_set(AukArr **pa, int64_t i, const void *e, const char *loc);
AUK_API void auk_arr_push(AukArr **pa, const void *e);
AUK_API bool auk_arr_pop(AukArr **pa, void *out);
AUK_API void auk_arr_insert(AukArr **pa, int64_t i, const void *e, const char *loc);
AUK_API void auk_arr_remove(AukArr **pa, int64_t i, void *out, const char *loc);
AUK_API void auk_arr_clear(AukArr **pa);
AUK_API AukArr *auk_arr_slice(AukArr *a, int64_t lo, int64_t hi, const char *loc);
AUK_API AukArr *auk_arr_take(AukArr *a, int64_t n);
AUK_API AukArr *auk_arr_skip(AukArr *a, int64_t n);
AUK_API AukArr *auk_arr_copy(const AukArr *a);
AUK_API AukArr *auk_arr_concat(const AukArr *a, const AukArr *b);
AUK_API void auk_arr_extend(AukArr **pa, const AukArr *b);
AUK_API AukArr *auk_arr_reversed(const AukArr *a);
AUK_API void auk_arr_reverse(AukArr **pa);
AUK_API void auk_arr_sort_with(AukArr **pa, int (*cmp)(const void *a, const void *b, void *ctx), void *ctx);
AUK_API void auk_arr_sort(AukArr **pa);
AUK_API AukArr *auk_arr_sorted(const AukArr *a);
AUK_API AukOpt_int auk_arr_index_of(const AukArr *a, const void *e);
AUK_API bool auk_arr_contains(const AukArr *a, const void *e);
AUK_API bool auk_arr_eq(const AukArr *a, const AukArr *b);
AUK_API int auk_arr_cmp(const AukArr *a, const AukArr *b);
AUK_API uint64_t auk_arr_hash(const AukArr *a);
AUK_API AukStr *auk_arr_show(const AukArr *a);
AUK_API AukStr *auk_arr_join(const AukArr *a, const AukStr *sep);
AUK_API int64_t auk_arr_sum_int(const AukArr *a, const char *loc);
AUK_API double auk_arr_sum_float(const AukArr *a);

/* ---- map.c: maps -------------------------------------------------------------------------- */

AUK_API int64_t auk_map_len(const AukMap *m);
AUK_API AukMap *auk_map_new(const AukElemOps *kops, const AukElemOps *vops);
void auk__map_free(AukMap *m);
AUK_API void *auk_map_find(const AukMap *m, const void *k);
AUK_API void *auk_map_at(const AukMap *m, const void *k, const char *loc);
AUK_API bool auk_map_get_opt(const AukMap *m, const void *k, void *out);
AUK_API bool auk_map_contains(const AukMap *m, const void *k);
AUK_API AukMap *auk_map_copy(const AukMap *m);
AUK_API void *auk_map_make_unique(AukMap **pm);
AUK_API void auk_map_set(AukMap **pm, const void *k, const void *v);
AUK_API bool auk_map_remove(AukMap **pm, const void *k, void *out);
AUK_API bool auk_map_next(const AukMap *m, int64_t *it, void **k, void **v);
AUK_API AukArr *auk_map_keys(const AukMap *m);
AUK_API AukArr *auk_map_values(const AukMap *m);
AUK_API bool auk_map_eq(const AukMap *a, const AukMap *b);
AUK_API AukStr *auk_map_show(const AukMap *m);

/* ---- task.c: tasks ------------------------------------------------------------------------ */

AUK_API extern _Atomic int64_t auk_cancel_pending;
extern _Atomic int64_t auk__live_reloads;
int64_t auk__cancel_running(bool (*pick)(void *ctx, uintptr_t entry, uintptr_t hint), void *ctx);
bool auk__task_cancelled(void);
bool auk__on_task(void);
void auk__check_cancel(const char *loc);
AUK_API void auk_cancel_check(const char *loc);
void auk__wait_fd(int fd, bool write);
void auk__sleep_ms(int64_t ms);
AUK_API bool auk_task_done(AukTask *t);
AUK_API int64_t auk_live_reloads(void);
AUK_API void auk_task_cancel(AukTask *t);
AUK_API int64_t auk_task_await_any(AukTask **ts, int64_t n, void *out, AukErr **err, const char *loc);
AUK_API AukTask *auk_task_spawn(AukThunk fn, const void *args, size_t args_size, size_t result_size, const AukElemOps *result_ops, void *heap, void (*args_drop)(void *args), const void *hint);
AUK_API void auk_task_await(AukTask *t, void *out);
AUK_API void auk_task_join_all(AukTask **ts, int64_t n);
AUK_API void auk_task_await_all(AukTask **ts, int64_t n, void *outs);
void auk__task_free(AukTask *t);

/* ---- chan.c: channels -------------------------------------------------------------------- */

AUK_API AukChan *auk_chan_new(AukArr *proto);
AUK_API void auk_chan_send(AukChan *c, const void *x, const char *loc);
AUK_API bool auk_chan_recv(AukChan *c, void *out);
AUK_API bool auk_chan_recv_for(AukChan *c, int64_t ms, void *out);
AUK_API void auk_chan_close(AukChan *c);
void auk__chan_free(AukChan *c);

/* ---- core.c: print, fs, net, time, rand, env, proc ------------------------------------- */

AukArr *auk__bytes_to_arr(const uint8_t *b, int64_t n);
AUK_API void auk_print(const AukStr *s);
AUK_API void auk_print_lit(const char *cstr);
AUK_API void auk_eprint(const AukStr *s);
AUK_API AukRes_str auk_fs_read(const AukStr *path);
AUK_API AukRes_unit auk_fs_write(const AukStr *path, const AukStr *content);
AUK_API AukRes_unit auk_fs_append(const AukStr *path, const AukStr *text);
AUK_API AukRes_arr auk_fs_lines(const AukStr *path);
AUK_API bool auk_fs_exists(const AukStr *path);
AUK_API bool auk_fs_is_dir(const AukStr *path);
AUK_API AukRes_arr auk_fs_list(const AukStr *dir);
AUK_API AukRes_unit auk_fs_mkdir(const AukStr *path);
AUK_API AukRes_unit auk_fs_remove(const AukStr *path);
AUK_API AukRes_unit auk_fs_rename(const AukStr *from, const AukStr *to);
AUK_API AukRes_str auk_fs_temp_dir(void);
AUK_API AukRes_arr auk_fs_read_bytes(const AukStr *path);
AUK_API AukRes_unit auk_fs_write_bytes(const AukStr *path, const AukArr *bytes);
extern const int auk__send_flags;
int auk__tcp_connect(const char *host, const char *port, const char **why, int *err);
AukConn *auk__conn_new(int fd);
AUK_API AukRes_conn auk_net_tcp(const AukStr *host, int64_t port);
AUK_API AukRes_listener auk_net_listen(const AukStr *host, int64_t port);
AUK_API AukRes_conn auk_listener_accept(AukListener *l);
AUK_API int64_t auk_listener_port(const AukListener *l);
AUK_API void auk_listener_close(AukListener *l);
void auk__listener_free(AukListener *l);
AUK_API AukRes_arr auk_conn_read(AukConn *c, int64_t max);
AUK_API AukRes_unit auk_conn_write(AukConn *c, const AukArr *bytes);
AUK_API void auk_conn_close(AukConn *c);
void auk__conn_free(AukConn *c);
AUK_API int64_t auk_time_now(void);
AUK_API void auk_time_sleep(int64_t ms);
AUK_API int64_t auk_rand_int(int64_t lo, int64_t hi);
AUK_API double auk_rand_float(void);
AUK_API void auk_rand_seed(int64_t seed);
AUK_API AukArr *auk_rand_bytes(int64_t n, const char *loc);
AUK_API AukOpt_str auk_env_get(const AukStr *key);
AUK_API void auk_env_set_args(int argc, char **argv);
AUK_API AukArr *auk_env_args(void);
AUK_API bool auk_env_is_terminal(int64_t fd);
AUK_API AukOpt_int auk_env_columns(void);
AUK_API AukOpt_str auk_env_read_line(void);
AUK_API AukRes_str auk_env_read_all(void);
AUK_API AukArr *auk_env_lines(void);
AUK_API AukRes_str auk_proc_run(const AukStr *cmd, const AukArr *args);
AUK_API _Noreturn void auk_proc_exit(int64_t code, const char *loc);

/* ---- testing.c: contracts, assert, peek, tests, program entry ------------------------- */

typedef AukErr *(*AukTestFn)(void);
typedef AukRes_int (*AukMainFn)(AukArr *args);
AUK_API _Noreturn void auk_requires_fail(const char *loc, const char *cond_text);
AUK_API _Noreturn void auk_ensures_fail(const char *loc, const char *cond_text);
AUK_API _Noreturn void auk_hole(const char *loc, const char *expected);
AUK_API _Noreturn void auk_assert_fail(const char *loc, const char *cond_text);
AUK_API _Noreturn void auk_assert_fail_cmp(const char *loc, const char *cond_text, const AukStr *left, const AukStr *right);
AUK_API void auk_peek(const char *loc, const char *src_text, const AukStr *shown);
AUK_API void auk_test_register(const char *name, AukTestFn fn);
AUK_API int auk_test_main(int argc, char **argv);
AUK_API int auk_main_wrapper(int argc, char **argv, AukMainFn user_main);

/* ---- compiler.c: helpers for generated code, the imprint evaluator ---------------------- */

AUK_API AukErr *auk__err_with_tag(const char *prefix, int tag);
AUK_API AukErr *auk__err_concat(const char *a, const AukStr *s, const char *b);
AUK_API uint64_t auk_hash_float(double x);
AUK_API uint64_t auk_value_hash(const AukValue *v);
AUK_API bool auk__imprint_open(int argc, const char *const *argv);
AUK_API void auk__imprint_close(void);
AUK_API void auk__imprint_mark(int tag, int64_t c);
AUK_API void auk__imprint_value(int64_t c, const AukValue *v);

/* ---- dbg.c: the debugger engine ---------------------------------------------------------- */

/* A frame record, as generated code lays it out. */
typedef struct AukFrame {
    int64_t func;
    struct AukFrame *parent;
    int64_t site;
    void *slots[];
} AukFrame;

/* An expression compiled for the debugger (src/dbg_eval.rs): a function of the addresses of
 * the locals it uses (in slots order) that returns the value shown, and its type. */
typedef struct AukDbgCompiled {
    AukStr *(*run)(void *const *slots);
    uint32_t *slots;
    int64_t nslots;
    char *ty;
} AukDbgCompiled;

/* Compile expr at site of debug function func: true with *out, or false with *err (malloc'd
 * strings and arrays, kept). */
typedef bool (*AukDbgEvalHook)(uint32_t func, uint32_t site, const char *expr, AukDbgCompiled *out, char **err);

AUK_API extern _Atomic int64_t auk_dbg_armed;
AUK_API void auk_dbg_set_eval_hook(AukDbgEvalHook h);
AUK_API void auk_dbg_enter(AukFrame *f);
AUK_API void auk_dbg_leave(AukFrame *f);
AUK_API void auk_dbg_hook(AukFrame *f);
AUK_API void auk_dbg_kid(void *ctx, const char *name, int64_t ty, void *p);
AUK_API void auk_dbg_kid_arr(void *ctx, void *list, int64_t ty, int64_t elem);
AUK_API void auk_dbg_kid_map(void *ctx, void *map, int64_t ty);
AUK_API void auk_dbg_init(const char *text, const AukShowFn *shows, const void *kids);
void auk__dbg_on_panic(const char *loc, const char *msg, size_t n, bool caught);
void auk__dbg_save(void **top, int64_t *depth);
void auk__dbg_restore(void *top, int64_t depth);

/* ---- still in Rust (runtime/src): declarations shrink as modules move to C -------------- */


/* TLS sessions (tls.rs). */
AukRes_arr auk__tls_read(void *tls, int64_t max);
AukRes_unit auk__tls_write(void *tls, const uint8_t *buf, int64_t n);
void auk__tls_free(void *tls);


/* The window process's entry (gui_host.rs). */
int auk__gui_host_main(void);


#endif
