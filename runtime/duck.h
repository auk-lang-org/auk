/*
 * duck.h -- the Duck C runtime ABI.
 *
 * Generated C code does `#include "duck.h"` and links the objects built from
 * the runtime .c files (C11, `-pthread -lm`, no third-party libraries).
 *
 * =====================================================================
 * OWNERSHIP CONVENTIONS (read this first)
 * =====================================================================
 *  1. Heap objects (DuckStr, DuckArr, DuckMap, DuckErr, DuckObj/DuckEnv,
 *     DuckTask, DuckConn, DuckListener) start with a DuckHeader and are reference counted.
 *     A freshly created object has rc == 1.
 *  2. Unless a comment says otherwise, function ARGUMENTS ARE BORROWED (the
 *     callee retains anything it keeps) and RETURNED OBJECTS ARE OWNED (+1;
 *     the caller must release them).  Results inside DuckOpt_* / DuckRes_*
 *     are owned too (both `val` and `err`).
 *  3. Elements passed *into* a container (push/set/insert, map set, Value
 *     constructors) are borrowed: the container retains its own copy using
 *     the element ops.  Elements written to a `void *out` parameter are owned
 *     by the caller.  `duck_arr_at` / `duck_map_at` / `duck_map_find` return
 *     a BORROWED pointer into the container's storage (valid until the
 *     container is mutated or released).
 *  4. Functions that mutate a container take `DuckArr **` / `DuckMap **` (a
 *     Duck `var`).  They copy first when the object is shared (rc > 1) or is
 *     a slice view (copy-on-write), so other holders never see the change.
 *  5. NULL is accepted everywhere a DuckStr* is read and means "".  retain and
 *     release accept NULL.  NULL is also accepted for empty DuckArr* and DuckMap*
 *     in read-only functions, but codegen should prefer real empty objects
 *     (an array needs its element ops).
 *  6. `loc` parameters are "file:line:col" strings used in panic messages.
 *
 * Panics print `panic: <msg>\n  at <loc>\n` to stderr and exit with 101.
 */
#ifndef DUCK_H
#define DUCK_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define DUCK_PRINTF(f, a) __attribute__((format(printf, f, a)))
#define DUCK_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define DUCK_PRINTF(f, a)
#define DUCK_UNLIKELY(x) (x)
#endif

/* =====================================================================
 * Common: headers, refcounting, panics
 * ===================================================================== */

/** Object kinds stored in DuckHeader.kind. */
enum {
    DUCK_K_STR = 1,
    DUCK_K_ARR = 2,
    DUCK_K_MAP = 3,
    DUCK_K_ERR = 4,
    DUCK_K_OBJ = 5, /* generic boxed object: closure env, enum box, user payload */
    DUCK_K_TASK = 6,
    DUCK_K_CONN = 7,
    DUCK_K_LISTENER = 8,
};

/** Every heap object begins with this. rc < 0 marks an immortal object. */
typedef struct DuckHeader {
    _Atomic int64_t rc;
    uint32_t kind;
} DuckHeader;

/** Retain any heap object (NULL-safe, immortal-safe). Returns p. */
void *duck_retain(void *p);
/** Release any heap object; frees it (releasing children) when rc hits 0. */
void duck_release(void *p);
/** Current reference count (for tests and COW checks). */
int64_t duck_refcount(const void *p);

/** Number of live runtime heap objects (debug leak counter; always 0 when
 *  built with -DDUCK_NO_LEAK_COUNTER). */
int64_t duck_live_objects(void);
/** Make p immortal: retain/release become no-ops and it no longer counts as live (for
 *  compiler-emitted globals such as string literals). NULL-safe. */
void duck_make_immortal(void *p);
/** Register the program's cleanup (releases its globals). When the environment variable
 *  DUCK_LEAK_CHECK is set, duck_main_wrapper and each forked test call it at exit and then
 *  fail (exit status 102 / a failed test) if any runtime objects are still live. */
void duck_set_cleanup(void (*fn)(void));
/** Run the cleanup and the leak check described above; returns the number of leaked objects
 *  (0 when DUCK_LEAK_CHECK is unset). Prints a message to stderr on a leak. */
int64_t duck_leak_check(void);

/** Print `panic: <msg>\n  at <loc>` to stderr and exit(101). */
_Noreturn void duck_panic(const char *loc, const char *fmt, ...) DUCK_PRINTF(2, 3);

/* ---- unit, scalars ---------------------------------------------------- */

/** `()` is represented by a byte (so `()!` has a well-formed `val`). */
typedef uint8_t DuckUnit;
#define DUCK_UNIT ((DuckUnit)0)

/* ---- checked int arithmetic (Duck `+ - * / % **` on int) ------------- */
_Noreturn void duck_panic_overflow(const char *loc, const char *op);
_Noreturn void duck_panic_div_zero(const char *loc);

static inline int64_t duck_add(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (DUCK_UNLIKELY(__builtin_add_overflow(a, b, &r))) duck_panic_overflow(loc, "+");
    return r;
}
static inline int64_t duck_sub(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (DUCK_UNLIKELY(__builtin_sub_overflow(a, b, &r))) duck_panic_overflow(loc, "-");
    return r;
}
static inline int64_t duck_mul(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (DUCK_UNLIKELY(__builtin_mul_overflow(a, b, &r))) duck_panic_overflow(loc, "*");
    return r;
}
/** Truncating division (like C). Panics on b == 0 and INT64_MIN / -1. */
static inline int64_t duck_div(int64_t a, int64_t b, const char *loc) {
    if (DUCK_UNLIKELY(b == 0)) duck_panic_div_zero(loc);
    if (DUCK_UNLIKELY(a == INT64_MIN && b == -1)) duck_panic_overflow(loc, "/");
    return a / b;
}
/** Remainder with the sign of the dividend (like C). Panics on b == 0. */
static inline int64_t duck_mod(int64_t a, int64_t b, const char *loc) {
    if (DUCK_UNLIKELY(b == 0)) duck_panic_div_zero(loc);
    if (DUCK_UNLIKELY(b == -1)) return 0;
    return a % b;
}
static inline int64_t duck_neg(int64_t a, const char *loc) {
    if (DUCK_UNLIKELY(a == INT64_MIN)) duck_panic_overflow(loc, "-");
    return -a;
}
/** a ** b. Panics on overflow and on a negative exponent. */
int64_t duck_pow(int64_t a, int64_t b, const char *loc);

/* ---- wrapping int ops (`+% -% *%`) ----------------------------------- */
static inline int64_t duck_wadd(int64_t a, int64_t b) { return (int64_t)((uint64_t)a + (uint64_t)b); }
static inline int64_t duck_wsub(int64_t a, int64_t b) { return (int64_t)((uint64_t)a - (uint64_t)b); }
static inline int64_t duck_wmul(int64_t a, int64_t b) { return (int64_t)((uint64_t)a * (uint64_t)b); }

/* ---- shifts (`<< >>`; `& | ^ ~` are plain C) ------------------------- */
/** a << n: bits shifted out are dropped (wraps). Panics unless 0 <= n <= 63. */
static inline int64_t duck_shl(int64_t a, int64_t n, const char *loc) {
    if (DUCK_UNLIKELY((uint64_t)n > 63)) duck_panic(loc, "shift amount %lld is outside 0..63", (long long)n);
    return (int64_t)((uint64_t)a << n);
}
/** a >> n: arithmetic (copies the sign bit). Panics unless 0 <= n <= 63. */
static inline int64_t duck_shr(int64_t a, int64_t n, const char *loc) {
    if (DUCK_UNLIKELY((uint64_t)n > 63)) duck_panic(loc, "shift amount %lld is outside 0..63", (long long)n);
    return a >> n;
}

/* ---- float ops -------------------------------------------------------- */
double duck_fpow(double a, double b);
double duck_fmod(double a, double b);
double duck_fsqrt(double a);
double duck_fabs(double a);
double duck_ffloor(double a);
double duck_fceil(double a);
double duck_fround(double a); /* half away from zero */
/** int(x): truncates toward zero; panics on NaN or out of range. */
int64_t duck_float_to_int(double x, const char *loc);
/** Total order used for sorting floats: -1, 0, 1 (NaN sorts last). */
int duck_float_cmp(double a, double b);
static inline int duck_int_cmp(int64_t a, int64_t b) { return (a > b) - (a < b); }
int64_t duck_int_abs(int64_t a, const char *loc);

/* =====================================================================
 * Element ops: how the runtime handles values stored inside containers
 * ===================================================================== */

typedef struct DuckStr DuckStr;

/** Operations on one element of a known static type. Function pointers
 *  receive a POINTER to the element. retain/release may be NULL for plain
 *  scalars; eq/cmp/hash/show may be NULL if the type lacks them (calling a
 *  missing op panics). `show` returns an owned DuckStr in "debug" form
 *  (strings quoted), as used when printing a container. */
typedef struct DuckElemOps {
    size_t size;
    void (*retain)(void *elem);
    void (*release)(void *elem);
    bool (*eq)(const void *a, const void *b);
    int (*cmp)(const void *a, const void *b);
    uint64_t (*hash)(const void *elem);
    DuckStr *(*show)(const void *elem);
} DuckElemOps;

extern const DuckElemOps duck_ops_int;     /* int64_t */
extern const DuckElemOps duck_ops_float;   /* double */
extern const DuckElemOps duck_ops_bool;    /* bool */
extern const DuckElemOps duck_ops_char;    /* uint32_t */
extern const DuckElemOps duck_ops_unit;    /* DuckUnit */
extern const DuckElemOps duck_ops_str;     /* DuckStr* */
extern const DuckElemOps duck_ops_arr;     /* DuckArr* (any element type) */
extern const DuckElemOps duck_ops_map;     /* DuckMap* (any key/value types) */
extern const DuckElemOps duck_ops_value;   /* DuckValue */
extern const DuckElemOps duck_ops_err;     /* DuckErr* */
extern const DuckElemOps duck_ops_obj;     /* DuckObj* (retain/release only) */
extern const DuckElemOps duck_ops_closure; /* DuckClosure (retain/release only) */
extern const DuckElemOps duck_ops_task;    /* DuckTask* (retain/release only) */

uint64_t duck_hash_bytes(const void *p, size_t n);
uint64_t duck_hash_int(int64_t x);
uint64_t duck_hash_combine(uint64_t h, uint64_t x);

/* =====================================================================
 * Optionals and results
 * ===================================================================== */

typedef struct DuckErr DuckErr;

/** Define `T?` as `typedef struct { bool some; T val; } Name;` */
#define DUCK_DEF_OPT(Name, T) \
    typedef struct Name {     \
        bool some;            \
        T val;                \
    } Name
/** Define `T!` / `T!E` as `typedef struct { bool ok; T val; DuckErr *err; } Name;`
 *  Exactly one of val (ok) / err (!ok) is meaningful and owned. */
#define DUCK_DEF_RES(Name, T) \
    typedef struct Name {     \
        bool ok;              \
        T val;                \
        DuckErr *err;         \
    } Name

#define DUCK_SOME(Name, v) ((Name){.some = true, .val = (v)})
#define DUCK_NONE(Name) ((Name){.some = false})
#define DUCK_OK(Name, v) ((Name){.ok = true, .val = (v), .err = NULL})
/** Takes ownership of e. */
#define DUCK_ERR(Name, e) ((Name){.ok = false, .err = (e)})

typedef struct DuckArr DuckArr;
typedef struct DuckMap DuckMap;
typedef struct DuckConn DuckConn;
typedef struct DuckListener DuckListener;
typedef struct DuckValue DuckValue;

DUCK_DEF_OPT(DuckOpt_int, int64_t);
DUCK_DEF_OPT(DuckOpt_float, double);
DUCK_DEF_OPT(DuckOpt_bool, bool);
DUCK_DEF_OPT(DuckOpt_char, uint32_t);
DUCK_DEF_OPT(DuckOpt_str, DuckStr *);
DUCK_DEF_OPT(DuckOpt_arr, DuckArr *);

DUCK_DEF_RES(DuckRes_unit, DuckUnit);
DUCK_DEF_RES(DuckRes_int, int64_t);
DUCK_DEF_RES(DuckRes_float, double);
DUCK_DEF_RES(DuckRes_str, DuckStr *);
DUCK_DEF_RES(DuckRes_arr, DuckArr *);
DUCK_DEF_RES(DuckRes_conn, DuckConn *);
DUCK_DEF_RES(DuckRes_listener, DuckListener *);

/** Panic for `x!` on none / on an Err (message includes the error chain). */
_Noreturn void duck_unwrap_none(const char *loc);
_Noreturn void duck_unwrap_err(const char *loc, DuckErr *e);

/* =====================================================================
 * str
 * ===================================================================== */

/** Immutable UTF-8 string. data is NUL-terminated (data[len_bytes] == 0). */
struct DuckStr {
    DuckHeader h;
    int64_t len_bytes;
    int64_t len_chars;
    bool is_ascii;
    char data[];
};

/** From a NUL-terminated C string that is known-valid UTF-8 (e.g. a literal
 *  emitted by the compiler). Invalid input is repaired like from_bytes. */
DuckStr *duck_str_lit(const char *cstr);
/** From n bytes; invalid UTF-8 sequences are replaced with U+FFFD, so the
 *  result is always valid. */
DuckStr *duck_str_from_bytes(const char *p, int64_t n);
/** From n bytes; Err("invalid UTF-8 at byte N") if invalid. */
DuckRes_str duck_str_try_from_bytes(const char *p, int64_t n);
/** str.from_utf8(bs: [int]): str!  (bytes outside 0..255 are an Err too) */
DuckRes_str duck_str_from_utf8(DuckArr *bytes);
/** Is p[0..n) valid UTF-8 (no overlongs/surrogates/> U+10FFFF)? If so and
 *  out-params are non-NULL, also returns char count and ASCII-ness. */
bool duck_utf8_valid(const char *p, int64_t n, int64_t *chars, bool *ascii);
/** Encode code point c into buf (>= 4 bytes); returns the byte count. */
int duck_utf8_encode(uint32_t c, char *buf);

static inline int64_t duck_str_len(const DuckStr *s) { return s ? s->len_chars : 0; }
static inline int64_t duck_str_byte_len(const DuckStr *s) { return s ? s->len_bytes : 0; }
static inline const char *duck_str_cstr(const DuckStr *s) { return s ? s->data : ""; }

/** s[i]: the i-th char. O(1) for ASCII strings. Panics when out of range. */
uint32_t duck_str_char_at(const DuckStr *s, int64_t i, const char *loc);
DuckOpt_char duck_str_get(const DuckStr *s, int64_t i);
/** s[a..b] by char index; panics unless 0 <= a <= b <= len. */
DuckStr *duck_str_slice(const DuckStr *s, int64_t a, int64_t b, const char *loc);
DuckStr *duck_str_concat(const DuckStr *a, const DuckStr *b);
bool duck_str_eq(const DuckStr *a, const DuckStr *b);
/** Byte order == code point order. Returns -1, 0, 1. */
int duck_str_cmp(const DuckStr *a, const DuckStr *b);
uint64_t duck_str_hash(const DuckStr *s);
/** Compare against a C string literal (handy for `match s { "GET" => ..}`). */
bool duck_str_eq_lit(const DuckStr *s, const char *lit);

/** split() on runs of whitespace (no empty pieces). -> [str] */
DuckArr *duck_str_split_ws(const DuckStr *s);
/** split(sep): every occurrence; "a,,b" -> ["a","","b"]. An empty sep splits
 *  into single chars. -> [str] */
DuckArr *duck_str_split(const DuckStr *s, const DuckStr *sep);
DuckStr *duck_str_trim(const DuckStr *s);
DuckStr *duck_str_trim_start(const DuckStr *s);
DuckStr *duck_str_trim_end(const DuckStr *s);
/** lines(): split on "\n", strip a trailing "\r", no final empty line. */
DuckArr *duck_str_lines(const DuckStr *s);
bool duck_str_starts_with(const DuckStr *s, const DuckStr *p);
bool duck_str_ends_with(const DuckStr *s, const DuckStr *p);
bool duck_str_contains(const DuckStr *s, const DuckStr *sub);
/** find(sub): char index of the first occurrence. */
DuckOpt_int duck_str_find(const DuckStr *s, const DuckStr *sub);
/** Replace every occurrence (an empty `from` returns s unchanged). */
DuckStr *duck_str_replace(const DuckStr *s, const DuckStr *from, const DuckStr *to);
/** ASCII case mapping; non-ASCII bytes are left untouched. */
DuckStr *duck_str_upper(const DuckStr *s);
DuckStr *duck_str_lower(const DuckStr *s);
DuckStr *duck_str_repeat(const DuckStr *s, int64_t n, const char *loc);
/** chars() -> [char] */
DuckArr *duck_str_chars(const DuckStr *s);
/** bytes() -> [int] (0..255) */
DuckArr *duck_str_bytes(const DuckStr *s);
/** str([char]) joins the chars. */
DuckStr *duck_str_from_chars(DuckArr *chars);

/** int.parse: optional sign, decimal digits, `_` between digits allowed.
 *  Surrounding whitespace is NOT allowed. Err on junk or overflow. */
DuckRes_int duck_int_parse(const DuckStr *s);
/** float.parse: decimal/exponent forms plus inf/nan; Err on junk. */
DuckRes_float duck_float_parse(const DuckStr *s);

bool duck_char_is_digit(uint32_t c);
bool duck_char_is_alpha(uint32_t c);  /* ASCII letters */
bool duck_char_is_space(uint32_t c);
uint32_t duck_char_upper(uint32_t c); /* ASCII */
uint32_t duck_char_lower(uint32_t c); /* ASCII */
/** char(n): char?  (none for surrogates and > 0x10FFFF or negative) */
DuckOpt_char duck_char_from_int(int64_t n);

/* ---- formatting (`str(x)` and interpolation) ------------------------- */
DuckStr *duck_str_from_int(int64_t v);
/** Shortest exact form that round-trips; always has '.' or an exponent:
 *  2.0, 0.1, -0.0, 1e21, 1.5e-7, NaN, inf, -inf. Exponent form is used
 *  when the decimal exponent is < -6 or >= 21. */
DuckStr *duck_str_from_float(double v);
DuckStr *duck_str_from_char(uint32_t c);
DuckStr *duck_str_from_bool(bool b);
/** Debug form: quoted with escapes, as containers show strings: "a\"b\n" */
DuckStr *duck_str_quote(const DuckStr *s);
DuckStr *duck_char_quote(uint32_t c);

/** Format specs (the text after ':' in `{x:spec}`), parsed at runtime:
 *      spec := [fill? align] ['0'] [width] ['.' precision]
 *      align := '<' | '>' | '^'
 *  Numbers default to right alignment, everything else to left.  '0' pads
 *  numbers with zeros after the sign.  Precision: fixed decimals for floats,
 *  max chars for strings, ignored for ints.  Width/precision count chars.
 *  A NULL or empty spec means plain str(x).  Malformed specs panic. */
DuckStr *duck_fmt_int(int64_t v, const char *spec);
DuckStr *duck_fmt_float(double v, const char *spec);
DuckStr *duck_fmt_str(const DuckStr *s, const char *spec);
DuckStr *duck_fmt_char(uint32_t c, const char *spec);
DuckStr *duck_fmt_bool(bool b, const char *spec);

/** Growable string builder for interpolation. Stack-allocate with
 *  DUCK_SB_INIT, push pieces, then duck_sb_finish (which frees the buffer). */
typedef struct DuckStrBuf {
    char *buf;
    int64_t len, cap;
} DuckStrBuf;
#define DUCK_SB_INIT ((DuckStrBuf){NULL, 0, 0})
void duck_sb_bytes(DuckStrBuf *b, const char *p, int64_t n);
void duck_sb_lit(DuckStrBuf *b, const char *cstr);
void duck_sb_str(DuckStrBuf *b, const DuckStr *s);
/** Push and release s (for owned temporaries like duck_fmt_int(..)). */
void duck_sb_str_own(DuckStrBuf *b, DuckStr *s);
void duck_sb_char(DuckStrBuf *b, uint32_t c);
void duck_sb_printf(DuckStrBuf *b, const char *fmt, ...) DUCK_PRINTF(2, 3);
DuckStr *duck_sb_finish(DuckStrBuf *b);
void duck_sb_free(DuckStrBuf *b);

/* =====================================================================
 * [T]
 * ===================================================================== */

/** An array. Elements are stored inline, elem_size = ops->size bytes each.
 *  An owner (base == NULL) owns `data` (malloc'd) and its elements.
 *  A slice view (base != NULL) points into base's buffer and keeps base
 *  alive; it never owns elements. Mutating a view or a shared array copies. */
struct DuckArr {
    DuckHeader h;
    const DuckElemOps *ops;
    int64_t len, cap;
    char *data;
    DuckArr *base;
};

DuckArr *duck_arr_new(const DuckElemOps *ops, int64_t cap);
/** Array literal: copies n elements from a C array, retaining each. */
DuckArr *duck_arr_from(const DuckElemOps *ops, const void *elems, int64_t n);
static inline int64_t duck_arr_len(const DuckArr *a) { return a ? a->len : 0; }
/** Read-only pointer to the first element (borrowed). */
static inline const void *duck_arr_data(const DuckArr *a) { return a ? a->data : NULL; }
/** xs[i]: borrowed pointer to element i; panics when out of range. */
void *duck_arr_at(const DuckArr *a, int64_t i, const char *loc);
/** xs.get(i): copies (and retains) element i into out; false if out of range. */
bool duck_arr_get_opt(const DuckArr *a, int64_t i, void *out);
/** Make *pa uniquely owned and writable (copy-on-write). Returns data. */
void *duck_arr_make_unique(DuckArr **pa);
/** xs[i] = v (COW). v is borrowed; the old element is released. */
void duck_arr_set(DuckArr **pa, int64_t i, const void *elem, const char *loc);
void duck_arr_push(DuckArr **pa, const void *elem);
/** Removes the last element into out (owned). False if empty. */
bool duck_arr_pop(DuckArr **pa, void *out);
/** Insert at i (0 <= i <= len), shifting the rest right. */
void duck_arr_insert(DuckArr **pa, int64_t i, const void *elem, const char *loc);
/** Remove element i into out (owned) or release it if out == NULL. */
void duck_arr_remove(DuckArr **pa, int64_t i, void *out, const char *loc);
void duck_arr_clear(DuckArr **pa);
/** xs[a..b]: O(1) view sharing the buffer; panics unless 0<=a<=b<=len. */
DuckArr *duck_arr_slice(DuckArr *a, int64_t lo, int64_t hi, const char *loc);
/** Like slice but clamps to the valid range (take/skip). */
DuckArr *duck_arr_take(DuckArr *a, int64_t n);
DuckArr *duck_arr_skip(DuckArr *a, int64_t n);
DuckArr *duck_arr_concat(const DuckArr *a, const DuckArr *b);
/** Append all of b to *pa (COW). */
void duck_arr_extend(DuckArr **pa, const DuckArr *b);
DuckArr *duck_arr_copy(const DuckArr *a);
DuckArr *duck_arr_reversed(const DuckArr *a);
void duck_arr_reverse(DuckArr **pa);
/** Stable sort with ops->cmp. */
DuckArr *duck_arr_sorted(const DuckArr *a);
void duck_arr_sort(DuckArr **pa);
/** Stable sort with a custom comparator (for sort_by). */
void duck_arr_sort_with(DuckArr **pa, int (*cmp)(const void *a, const void *b, void *ctx), void *ctx);
bool duck_arr_contains(const DuckArr *a, const void *elem);
DuckOpt_int duck_arr_index_of(const DuckArr *a, const void *elem);
bool duck_arr_eq(const DuckArr *a, const DuckArr *b);
int duck_arr_cmp(const DuckArr *a, const DuckArr *b); /* lexicographic */
uint64_t duck_arr_hash(const DuckArr *a);
/** [1, 2, 3] / ["a", "b"] */
DuckStr *duck_arr_show(const DuckArr *a);
/** join(sep): str and char elements are inserted raw, others via show. */
DuckStr *duck_arr_join(const DuckArr *a, const DuckStr *sep);
int64_t duck_arr_sum_int(const DuckArr *a, const char *loc);
double duck_arr_sum_float(const DuckArr *a);

/** Typed convenience: DUCK_ARR_AT(int64_t, xs, i, loc) is an lvalue. */
#define DUCK_ARR_AT(T, a, i, loc) (*(T *)duck_arr_at((a), (i), (loc)))
/** Push an rvalue: DUCK_ARR_PUSH(int64_t, &xs, 42). (Borrowed.) */
#define DUCK_ARR_PUSH(T, pa, v)    \
    do {                           \
        T duck_tmp_ = (v);         \
        duck_arr_push((pa), &duck_tmp_); \
    } while (0)

/* =====================================================================
 * {K: V}
 * ===================================================================== */

/** Insertion-ordered hash map: an open-addressing index over an entries
 *  array (keys, values, hashes, tombstones). Copy-on-write like arrays. */
struct DuckMap {
    DuckHeader h;
    const DuckElemOps *kops, *vops;
    int64_t len;      /* live entries */
    int64_t n;        /* used entry slots (live + removed) */
    int64_t cap;      /* entry capacity */
    char *keys;       /* cap * kops->size */
    char *vals;       /* cap * vops->size */
    uint64_t *hashes; /* cap */
    bool *dead;       /* cap */
    int64_t *index;   /* icap slots: -1 empty, -2 tombstone, else entry idx */
    int64_t icap;
};

DuckMap *duck_map_new(const DuckElemOps *kops, const DuckElemOps *vops);
static inline int64_t duck_map_len(const DuckMap *m) { return m ? m->len : 0; }
/** m[k]: borrowed pointer to the value; panics "key not found: <k>". */
void *duck_map_at(const DuckMap *m, const void *key, const char *loc);
/** Borrowed pointer to the value or NULL. */
void *duck_map_find(const DuckMap *m, const void *key);
/** m.get(k): copies (and retains) the value into out; false if missing. */
bool duck_map_get_opt(const DuckMap *m, const void *key, void *out);
bool duck_map_contains(const DuckMap *m, const void *key);
/** m[k] = v: insert at the end or replace in place (COW). Borrowed k, v. */
void duck_map_set(DuckMap **pm, const void *key, const void *val);
/** Remove k; the value goes to out (owned) or is released if out == NULL.
 *  Returns false if k was missing. Remaining entries keep their order. */
bool duck_map_remove(DuckMap **pm, const void *key, void *out);
void *duck_map_make_unique(DuckMap **pm);
DuckMap *duck_map_copy(const DuckMap *m);
/** Iterate in insertion order:
 *      int64_t it = 0; void *k, *v;
 *      while (duck_map_next(m, &it, &k, &v)) { ... }   // borrowed k, v */
bool duck_map_next(const DuckMap *m, int64_t *it, void **key, void **val);
DuckArr *duck_map_keys(const DuckMap *m);
DuckArr *duck_map_values(const DuckMap *m);
bool duck_map_eq(const DuckMap *a, const DuckMap *b); /* order-insensitive */
/** {"a": 1, "b": 2} */
DuckStr *duck_map_show(const DuckMap *m);

/* =====================================================================
 * Err
 * ===================================================================== */

/** Optional typed payload so `err(BadUrl(w))` still matches after a typed
 *  error was converted to Err. data is a heap copy owned by the DuckErr. */
typedef struct DuckErrPayload {
    uint32_t type_id; /* 0 = none; ids are assigned by the compiler */
    void *data;
    const DuckElemOps *ops;
} DuckErrPayload;

struct DuckErr {
    DuckHeader h;
    DuckStr *msg;
    int64_t code;
    DuckErr *cause; /* owned, may be NULL */
    DuckErrPayload payload;
};

/** New error; msg is borrowed. */
DuckErr *duck_err_new(const DuckStr *msg);
/** New error from a printf format. */
DuckErr *duck_err_fmt(const char *fmt, ...) DUCK_PRINTF(1, 2);
/** New error wrapping cause (cause is borrowed/retained). */
DuckErr *duck_err_wrap(const DuckStr *msg, DuckErr *cause);
/** An error carrying a typed value (copied and retained via ops). The
 *  message is ops->show(value) when msg is NULL. */
DuckErr *duck_err_typed(uint32_t type_id, const void *value, const DuckElemOps *ops, const DuckStr *msg);
/** Borrowed pointer to the payload if its type id matches, else NULL. */
const void *duck_err_payload(const DuckErr *e, uint32_t type_id);
/** "msg: cause: cause2" -- what `"{e}"` prints. */
DuckStr *duck_err_show(const DuckErr *e);

/* =====================================================================
 * Boxed objects and closures
 * ===================================================================== */

/** Generic heap object with a destructor. Embed as the FIRST member of a
 *  generated struct, allocate with duck_obj_alloc(sizeof(MyStruct), drop).
 *  drop releases the RC fields (it must not free the object itself). Used
 *  for closure environments and boxed recursive enum fields. */
typedef struct DuckObj {
    DuckHeader h;
    void (*drop)(struct DuckObj *self);
} DuckObj;
typedef DuckObj DuckEnv;
typedef DuckObj DuckBox;

/** Zero-initialized allocation of `size` bytes (size >= sizeof(DuckObj)). */
void *duck_obj_alloc(size_t size, void (*drop)(DuckObj *self));

/** A closure value: call as ((R (*)(DuckEnv *, A...))c.fn)(c.env, args...).
 *  env may be NULL for closures that capture nothing. */
typedef struct DuckClosure {
    void *fn;
    DuckEnv *env;
} DuckClosure;
#define DUCK_CLOSURE_CALL(c, FnType, ...) (((FnType)(c).fn)((c).env, __VA_ARGS__))
#define DUCK_CLOSURE_CALL0(c, FnType) (((FnType)(c).fn)((c).env))
static inline void duck_closure_retain(DuckClosure c) { duck_retain(c.env); }
static inline void duck_closure_release(DuckClosure c) { duck_release(c.env); }

/** Helpers for generated struct/tuple/enum copy & drop functions. */
#define DUCK_RETAIN(p) ((void)duck_retain((void *)(p)))
#define DUCK_RELEASE(p) duck_release((void *)(p))
/** Release and clear a pointer variable or field. */
#define DUCK_CLEAR(p)                 \
    do {                              \
        duck_release((void *)(p));    \
        (p) = NULL;                   \
    } while (0)
/** Replace an owned pointer field: retains v, releases the old value. */
#define DUCK_ASSIGN(field, v)                  \
    do {                                       \
        void *duck_old_ = (void *)(field);     \
        (field) = duck_retain((void *)(v));    \
        duck_release(duck_old_);               \
    } while (0)

/* =====================================================================
 * Value (core enum)
 * ===================================================================== */

typedef enum DuckValueTag {
    DUCK_V_NULL = 0,
    DUCK_V_BOOL,
    DUCK_V_INT,
    DUCK_V_FLOAT,
    DUCK_V_STR,
    DUCK_V_LIST, /* [Value] */
    DUCK_V_MAP,  /* {str: Value} */
} DuckValueTag;

struct DuckValue {
    DuckValueTag tag;
    union {
        bool b;
        int64_t i;
        double f;
        DuckStr *s;
        DuckArr *list;
        DuckMap *map;
    } u;
};

DUCK_DEF_OPT(DuckOpt_value, DuckValue);
DUCK_DEF_RES(DuckRes_value, DuckValue);

DuckValue duck_value_null(void);
DuckValue duck_value_bool(bool b);
DuckValue duck_value_int(int64_t i);
DuckValue duck_value_float(double f);
DuckValue duck_value_str(DuckStr *s);   /* retains s */
DuckValue duck_value_list(DuckArr *xs); /* retains xs (elements: duck_ops_value) */
DuckValue duck_value_map(DuckMap *m);   /* retains m (str -> Value) */
/** Fresh empty containers with the right element ops. */
DuckArr *duck_value_list_new(void);
DuckMap *duck_value_map_new(void);
/** Convenience: v[key] = val in a Value map (borrowed key text, val). */
void duck_value_map_put(DuckMap **pm, const char *key, DuckValue val);
void duck_value_retain(DuckValue v);
void duck_value_release(DuckValue v);
/** Accessors panic on a tag mismatch ("expected Int, got Str"). */
bool duck_value_as_bool(DuckValue v, const char *loc);
int64_t duck_value_as_int(DuckValue v, const char *loc);
double duck_value_as_float(DuckValue v, const char *loc); /* Int widens */
DuckStr *duck_value_as_str(DuckValue v, const char *loc); /* borrowed */
DuckArr *duck_value_as_list(DuckValue v, const char *loc); /* borrowed */
DuckMap *duck_value_as_map(DuckValue v, const char *loc); /* borrowed */
const char *duck_value_tag_name(DuckValueTag t);
bool duck_value_eq(DuckValue a, DuckValue b);
/** Duck-literal-ish form: Null, true, 1, 2.0, "s", [..], {"k": v}. */
DuckStr *duck_value_show(DuckValue v);

/* =====================================================================
 * Async tasks
 * ===================================================================== */

/** A thunk computes the task result from its argument block:
 *      void thunk(void *args, void *result);
 *  `args` is a runtime-owned copy of the block passed to spawn; the thunk
 *  owns the RC values inside it (it must release them or move them into
 *  the result). `result` points to result_size zeroed bytes. */
typedef void (*DuckThunk)(void *args, void *result);

typedef struct DuckTask DuckTask;

/** Start fn on a new thread (one pthread per task, 8 MiB stack). args
 *  (args_size bytes) is copied; ownership of its RC fields moves to the
 *  task. The task keeps its own reference to the result; result_ops (NULL for
 *  plain data) is used to retain the copy handed out by each await and to
 *  release the task's copy when the task is freed. Releasing a task that is
 *  still running joins it first. */
DuckTask *duck_task_spawn(DuckThunk fn, const void *args, size_t args_size, size_t result_size,
                          const DuckElemOps *result_ops);
/** await t: join, then copy (and retain) the result into out, which the
 *  caller owns. Can be called more than once and from several threads. */
void duck_task_await(DuckTask *t, void *out);
/** Join every task (all are already running); then await each for results. */
void duck_task_join_all(DuckTask **ts, int64_t n);
/** await_all: join all, then copy result i into (char*)outs + i*result_size. */
void duck_task_await_all(DuckTask **ts, int64_t n, void *outs);

/* =====================================================================
 * Core library
 * ===================================================================== */

/* print / eprint: write s and a newline. */
void duck_print(const DuckStr *s);
void duck_print_lit(const char *cstr);
void duck_eprint(const DuckStr *s);

/* fs */
DuckRes_str duck_fs_read(const DuckStr *path);
DuckRes_unit duck_fs_write(const DuckStr *path, const DuckStr *content);
DuckRes_arr duck_fs_lines(const DuckStr *path); /* [str] */
bool duck_fs_exists(const DuckStr *path);
bool duck_fs_is_dir(const DuckStr *path);
/** The entry names of dir (no "." or ".."), sorted bytewise: [str]. */
DuckRes_arr duck_fs_list(const DuckStr *dir);
/** mkdir -p: creates missing parents; Ok if path is already a directory. */
DuckRes_unit duck_fs_mkdir(const DuckStr *path);
/** Removes a file, symlink or empty directory. */
DuckRes_unit duck_fs_remove(const DuckStr *path);
DuckRes_unit duck_fs_rename(const DuckStr *from, const DuckStr *to);
DuckRes_unit duck_fs_append(const DuckStr *path, const DuckStr *text);
/** A new, empty, private (0700) directory under $TMPDIR (or /tmp); the caller removes it. */
DuckRes_str duck_fs_temp_dir(void);
/** The file's bytes as [int] (0..255). */
DuckRes_arr duck_fs_read_bytes(const DuckStr *path);
/** Writes bytes ([int]); an Err, before the file is touched, if one is outside 0..255. */
DuckRes_unit duck_fs_write_bytes(const DuckStr *path, const DuckArr *bytes);

/* net */
struct DuckConn {
    DuckHeader h;
    int fd;    /* the socket; -1 when closed (or when `tls` owns the transport) */
    void *tls; /* a TLS session (runtime/tls.c), or NULL for plain TCP */
};
DuckRes_conn duck_net_tcp(const DuckStr *host, int64_t port);
/** A TLS client connection that verifies the server's certificate chain against the system
 *  trust store and its name against `host` (runtime/tls.c: Network.framework on macOS, a
 *  dlopen'ed OpenSSL elsewhere). Err("tls unavailable in this build") when neither exists. */
DuckRes_conn duck_net_tls(const DuckStr *host, int64_t port);
/** A listening TCP socket. */
struct DuckListener {
    DuckHeader h;
    int fd; /* -1 when closed */
    int64_t port;
};
/** Bind and listen on host:port ("" = every interface; port 0 = a free port). */
DuckRes_listener duck_net_listen(const DuckStr *host, int64_t port);
/** Wait for the next connection (blocks the calling task's thread). */
DuckRes_conn duck_listener_accept(DuckListener *l);
/** The bound port (the one the OS picked for port 0). */
int64_t duck_listener_port(const DuckListener *l);
void duck_listener_close(DuckListener *l);
/** read(max): [int]! -- an empty array means the peer closed. */
DuckRes_arr duck_conn_read(DuckConn *c, int64_t max);
/** write(bytes: [int]): ()! -- writes everything. */
DuckRes_unit duck_conn_write(DuckConn *c, const DuckArr *bytes);
void duck_conn_close(DuckConn *c);

/* time */
int64_t duck_time_now(void); /* ms since the Unix epoch */
void duck_time_sleep(int64_t ms);

/* rand: uniform in [lo, hi] (both inclusive); panics if lo > hi. */
int64_t duck_rand_int(int64_t lo, int64_t hi);
double duck_rand_float(void); /* [0, 1) */
/** Reseed the rand.int/rand.float generator deterministically (for tests; not
 *  cryptographic). Does not affect duck_rand_bytes. */
void duck_rand_seed(int64_t seed);
/** n bytes ([int], 0..255) from the OS CSPRNG (arc4random_buf, getrandom or
 *  /dev/urandom); panics if n < 0. */
DuckArr *duck_rand_bytes(int64_t n, const char *loc);

/* env */
DuckOpt_str duck_env_get(const DuckStr *key);
/** Program arguments (argv[0] included) as [str]; set by duck_main_wrapper
 *  or duck_env_set_args. */
DuckArr *duck_env_args(void);
void duck_env_set_args(int argc, char **argv);
/** stdin (flushes stdout first). read_line: the next line without its "\n" or
 *  "\r\n", none at EOF; invalid UTF-8 is replaced with U+FFFD, as in lines. */
DuckOpt_str duck_env_read_line(void);
/** The rest of stdin; Err on a read error or invalid UTF-8. */
DuckRes_str duck_env_read_all(void);
/** The rest of stdin split into lines ([str], as duck_str_lines). */
DuckArr *duck_env_lines(void);

/* proc.run(cmd, args): runs cmd (PATH lookup) with args, returns stdout.
 * Err if it can't start or exits non-zero (code = exit status). */
DuckRes_str duck_proc_run(const DuckStr *cmd, const DuckArr *args);
/** proc.exit(code): flush stdout and stderr, run the DUCK_LEAK_CHECK check
 *  (exit 102 on a leak) and end the process with code (0..255, else a panic). */
_Noreturn void duck_proc_exit(int64_t code, const char *loc);

/* =====================================================================
 * Contracts, holes, peek, assert, tests, program entry
 * ===================================================================== */

/** panic "requires failed: <cond>" */
_Noreturn void duck_requires_fail(const char *loc, const char *cond_text);
/** panic "ensures failed: <cond>" */
_Noreturn void duck_ensures_fail(const char *loc, const char *cond_text);
/** panic "unfilled hole (expected <expected>)" */
_Noreturn void duck_hole(const char *loc, const char *expected);
/** panic "assertion failed: <cond>" */
_Noreturn void duck_assert_fail(const char *loc, const char *cond_text);
/** As above plus "\n  left: <l>\n  right: <r>" (l, r borrowed). */
_Noreturn void duck_assert_fail_cmp(const char *loc, const char *cond_text, const DuckStr *left,
                                    const DuckStr *right);
/** peek: prints `[loc] <src_text> = <shown>` to stderr. shown is borrowed. */
void duck_peek(const char *loc, const char *src_text, const DuckStr *shown);

/** A test body: returns NULL on success or an owned Err (from ?/fail()). */
typedef DuckErr *(*DuckTestFn)(void);
void duck_test_register(const char *name, DuckTestFn fn);
/** Runs each registered test in a forked child; prints `ok <name>` or
 *  `FAIL <name>` (followed by the child's output, indented) and a final
 *  `N passed, M failed`. Returns 0, or 1 if any test failed. argv[1], if
 *  present, filters tests by substring. */
int duck_test_main(int argc, char **argv);

/** Program entry. The user's main is adapted by codegen to this shape
 *  (args may be ignored; a plain int/() main returns DUCK_OK). An Err prints
 *  `error: <msg and causes>` to stderr and returns 1; otherwise returns the
 *  int.  Use as: `int main(int c, char **v) { return duck_main_wrapper(c, v, duck_user_main); }` */
typedef DuckRes_int (*DuckMainFn)(DuckArr *args);
int duck_main_wrapper(int argc, char **argv, DuckMainFn user_main);

/* =====================================================================
 * Execution traces (runtime/trace.c)
 * =====================================================================
 * Only programs compiled with tracing (`duck run --trace`, `duck test --trace`) call these:
 * their `main` calls duck_trace_init, and each traced function is wrapped as
 *
 *     if (!duck_trace_begin()) return f_untraced(a0);
 *     DuckStr *args[1] = {show(a0)};
 *     duck_trace_call("mod.f", "file:line:col", 1, args);
 *     R r = f_untraced(a0);
 *     if (duck_trace_exit()) duck_trace_ret("mod.f", show(r));   // or duck_trace_err
 *     return r;
 *
 * Events are JSON Lines; DUCK_TRACE, DUCK_TRACE_LIMIT and DUCK_TRACE_TAIL configure them (see
 * trace.c). Values are shown with their (debug) Show, cut to 200 chars. */

/** Is an event stream recording? (false when off or past the event limit) */
extern bool duck_trace_live;
/** The call site ("file:line:col") of the next traced call; set by the caller, consumed by
 *  duck_trace_begin. The definition's location is used when it is NULL. */
extern _Thread_local const char *duck_trace_site;
/** Read the configuration; `tests`: this is a test binary (each test child starts its own
 *  trace) rather than a program (traced from the start). */
void duck_trace_init(bool tests);
/** Should this call be traced? When true, the caller must show its arguments and then call
 *  duck_trace_call (nothing is traced in between, so a user `show` isn't). */
bool duck_trace_begin(void);
/** The call event. Consumes (releases) the n shown args. */
void duck_trace_call(const char *fn, const char *loc, int n, DuckStr **args);
/** After a traced call returns: should its result be recorded? When true, the caller must
 *  call duck_trace_ret or duck_trace_err. */
bool duck_trace_exit(void);
/** The return event; consumes `shown` (NULL = a function returning `()`). */
void duck_trace_ret(const char *fn, DuckStr *shown);
/** The error event of a `T!` function that returned an Err (borrowed). */
void duck_trace_err(const char *fn, const DuckErr *e);

#ifdef __cplusplus
}
#endif
#endif /* DUCK_H */
