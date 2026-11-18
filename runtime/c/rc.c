/* Refcounting, allocation, panics, arithmetic, hashing and the scalar element ops. */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "auk_rt.h"

/* ---- allocation & leak counter ----------------------------------------------------------- */

static _Atomic int64_t live_objects;

AUK_API int64_t auk_live_objects(void) {
    return atomic_load(&live_objects);
}

/* The live objects that aren't the program's: a compiler written in Auk runs the programs it
 * compiles in its own process, where its own objects stay live, so it marks them just before
 * calling the program's entry point, and the leak check counts from there. */
static _Atomic int64_t leak_baseline;

AUK_API void auk_leak_baseline(void) {
    atomic_store(&leak_baseline, atomic_load(&live_objects));
}

static _Noreturn void oom(void) {
    fputs("panic: out of memory\n", stderr);
    _exit(101);
}

void *auk__xmalloc(size_t n) {
    void *p = malloc(n == 0 ? 1 : n);
    if (p == NULL) {
        oom();
    }
    return p;
}

void *auk__xcalloc(size_t n, size_t size) {
    void *p = calloc(n == 0 ? 1 : n, size == 0 ? 1 : size);
    if (p == NULL) {
        oom();
    }
    return p;
}

void *auk__xrealloc(void *p, size_t n) {
    void *q = realloc(p, n == 0 ? 1 : n);
    if (q == NULL) {
        oom();
    }
    return q;
}

/* A zeroed heap object with rc 1 (counted as live). */
void *auk__alloc(size_t size, uint32_t kind) {
    AukHeader *h = auk__heap_alloc(size, kind);
    atomic_store_explicit(&h->rc, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&live_objects, 1, memory_order_relaxed);
    return h;
}

/* Free the object memory itself (and update the live counter). */
void auk__free_obj(void *p) {
    atomic_fetch_sub_explicit(&live_objects, 1, memory_order_relaxed);
    auk__heap_free(p);
}

void auk__make_immortal(void *p) {
    if (p == NULL) {
        return;
    }
    AukHeader *h = p;
    if (atomic_load(&h->rc) < 0) {
        return;
    }
    atomic_store(&h->rc, INT64_MIN / 2);
    atomic_fetch_sub_explicit(&live_objects, 1, memory_order_relaxed);
}

AUK_API void auk_make_immortal(void *p) {
    auk__make_immortal(p);
}

static pthread_mutex_t cleanup_lock = PTHREAD_MUTEX_INITIALIZER;
static void (*cleanup)(void);

AUK_API void auk_set_cleanup(void (*f)(void)) {
    pthread_mutex_lock(&cleanup_lock);
    cleanup = f;
    pthread_mutex_unlock(&cleanup_lock);
}

AUK_API int64_t auk_leak_check(void) {
    if (getenv("AUK_LEAK_CHECK") == NULL) {
        return 0;
    }
    pthread_mutex_lock(&cleanup_lock);
    void (*f)(void) = cleanup;
    pthread_mutex_unlock(&cleanup_lock);
    if (f != NULL) {
        f();
    }
    int64_t n = auk_live_objects() - atomic_load(&leak_baseline);
    if (n != 0) {
        fflush(stdout);
        fprintf(stderr, "leak: %lld runtime object(s) still live at exit\n", (long long)n);
        fflush(stderr);
    }
    return n;
}

AUK_API void *auk_retain(void *p) {
    if (p == NULL) {
        return p;
    }
    AukHeader *h = p;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) < 0) {
        return p;
    }
    atomic_fetch_add_explicit(&h->rc, 1, memory_order_relaxed);
    if (auk__is_handle(h->kind)) {
        auk__note_handle(p, 1);
    }
    return p;
}

AUK_API void auk_release(void *p) {
    if (p == NULL) {
        return;
    }
    AukHeader *h = p;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) < 0) {
        return;
    }
    if (auk__is_handle(h->kind)) {
        auk__note_handle(p, -1);
    }
    if (atomic_fetch_sub_explicit(&h->rc, 1, memory_order_release) != 1) {
        return;
    }
    atomic_thread_fence(memory_order_acquire);
    auk__free_now(p);
}

/* The slow end of auk_release inlined by the LLVM back end: generated code has already dropped
 * the last reference (its decrement returned 1) and issued the acquire fence. */
AUK_API void auk__free_last(void *p) {
    auk__free_now(p);
}

/* Write n in decimal to buf (at least 21 bytes); returns buf. */
static const char *dec(int64_t n, char *buf) {
    char tmp[21];
    int i = 0;
    uint64_t u = n < 0 ? (uint64_t)0 - (uint64_t)n : (uint64_t)n;
    do {
        tmp[i++] = (char)('0' + u % 10);
        u /= 10;
    } while (u != 0);
    int j = 0;
    if (n < 0) {
        buf[j++] = '-';
    }
    while (i > 0) {
        buf[j++] = tmp[--i];
    }
    buf[j] = 0;
    return buf;
}

/* Free an object whose last reference is gone (or whose heap is being swept): release what it
 * holds and free its memory, by kind. */
void auk__free_now(void *p) {
    AukHeader *h = p;
    switch (h->kind) {
    case AUK_K_STR:
        auk__str_free(p);
        return;
    case AUK_K_ARR:
        auk__arr_free(p);
        return;
    case AUK_K_MAP:
        auk__map_free(p);
        return;
    case AUK_K_ERR:
        auk__err_free(p);
        return;
    case AUK_K_TASK:
        auk__task_free(p);
        return;
    case AUK_K_CONN:
        auk__conn_free(p);
        return;
    case AUK_K_LISTENER:
        auk__listener_free(p);
        return;
    case AUK_K_CHAN:
        auk__chan_free(p);
        return;
    case AUK_K_FRAME:
        auk__free_obj(p);
        return;
    case AUK_K_OBJ: {
        AukObj *o = p;
        if (o->drop != NULL) {
            o->drop(o);
        }
        auk__free_obj(p);
        return;
    }
    default: {
        char buf[21];
        auk__panic3("runtime", "release of an object with unknown kind ", dec(h->kind, buf), NULL);
    }
    }
}

AUK_API int64_t auk_refcount(const void *p) {
    if (p == NULL) {
        return 0;
    }
    return atomic_load(&((AukHeader *)p)->rc);
}

/* ---- panics ------------------------------------------------------------------------------ */

/* The one panic path: flush stdout, print `panic: <msg>\n  at <loc>`, record it in the trace,
 * and _exit(101) (no atexit handlers: other threads may still be busy). Under a recovery point
 * (`catch`, a task thread) it jumps back there instead (catch.c). */
_Noreturn void auk__panic(const char *loc, const char *msg, size_t n) {
    fflush(stdout);
    /* messages are bounded at 2047 bytes, cut at a UTF-8 boundary */
    if (n > 2047) {
        n = 2047;
        while (n > 0 && ((uint8_t)msg[n] & 0xC0) == 0x80) {
            n--;
        }
    }
    const char *where = loc == NULL ? "<unknown>" : loc;
    bool caught = auk__catch_active() != 0;
    auk__dbg_on_panic(where, msg, n, caught);
    if (caught) {
        auk__trace_on_panic(loc, msg, n, true);
        auk__catch_throw(where, msg, n);
    }
    fputs("panic: ", stderr);
    fwrite(msg, 1, n, stderr);
    fputs("\n  at ", stderr);
    fputs(where, stderr);
    fputs("\n", stderr);
    fflush(stderr);
    auk__trace_on_panic(loc, msg, n, false);
    _exit(101);
}

/* The text of the panic being raised on this thread: messages are bounded at 2047 bytes
 * (auk__panic), and a caught panic doesn't leak a buffer (catch.c copies what it keeps). */
static _Thread_local char panic_buf[2048];

/* Panic with the n bytes at p (anything past the bound is dropped here; auk__panic then cuts
 * the message at a UTF-8 boundary). */
_Noreturn void auk__panic_bytes(const char *loc, const char *p, size_t n) {
    if (n > sizeof panic_buf - 1) {
        n = sizeof panic_buf - 1;
    }
    if (n > 0 && p != panic_buf) {
        memmove(panic_buf, p, n);
    }
    panic_buf[n] = 0;
    auk__panic(loc, panic_buf, n);
}

_Noreturn void auk__panic3(const char *loc, const char *a, const char *b, const char *c) {
    const char *parts[3] = {a, b, c};
    size_t n = 0;
    for (int i = 0; i < 3; i++) {
        size_t k = parts[i] == NULL ? 0 : strlen(parts[i]);
        if (k > sizeof panic_buf - 1 - n) {
            k = sizeof panic_buf - 1 - n;
        }
        if (k > 0) {
            memcpy(panic_buf + n, parts[i], k);
        }
        n += k;
    }
    panic_buf[n] = 0;
    auk__panic(loc, panic_buf, n);
}

_Noreturn void auk__panic_rt(const char *msg) {
    auk__panic3("runtime", msg, NULL, NULL);
}

uint8_t *auk__tmp_get(AukTmp *t, size_t size) {
    t->heap = size <= sizeof t->stack ? NULL : auk__xmalloc(size);
    return t->heap == NULL ? t->stack : t->heap;
}

void auk__tmp_done(AukTmp *t) {
    free(t->heap);
}

/* The panic entry point for generated code: msg is NUL-terminated. */
AUK_API _Noreturn void auk_panic_str(const char *loc, const char *msg) {
    auk__panic(loc, msg == NULL ? "" : msg, msg == NULL ? 0 : strlen(msg));
}

AUK_API _Noreturn void auk_panic_overflow(const char *loc, const char *op) {
    auk__panic3(loc, "integer overflow in `", op, "`");
}

AUK_API _Noreturn void auk_panic_div_zero(const char *loc) {
    auk__panic3(loc, "division by zero", NULL, NULL);
}

AUK_API _Noreturn void auk_unwrap_none(const char *loc) {
    auk__panic3(loc, "unwrapped `none`", NULL, NULL);
}

AUK_API _Noreturn void auk_unwrap_err(const char *loc, AukErr *e) {
    AukStr *s = auk_err_show(e);
    static const char prefix[] = "unwrapped an error: ";
    char m[2048];
    size_t np = sizeof prefix - 1;
    size_t ns = (size_t)s->len_bytes < sizeof m - np ? (size_t)s->len_bytes : sizeof m - np;
    memcpy(m, prefix, np);
    memcpy(m + np, s->data, ns);
    auk_release(s);
    auk__panic_bytes(loc, m, np + ns);
}

/* ---- arithmetic -------------------------------------------------------------------------- */

AUK_API int64_t auk_add(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (__builtin_add_overflow(a, b, &r)) {
        auk_panic_overflow(loc, "+");
    }
    return r;
}

AUK_API int64_t auk_sub(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (__builtin_sub_overflow(a, b, &r)) {
        auk_panic_overflow(loc, "-");
    }
    return r;
}

AUK_API int64_t auk_mul(int64_t a, int64_t b, const char *loc) {
    int64_t r;
    if (__builtin_mul_overflow(a, b, &r)) {
        auk_panic_overflow(loc, "*");
    }
    return r;
}

AUK_API int64_t auk_div(int64_t a, int64_t b, const char *loc) {
    if (b == 0) {
        auk_panic_div_zero(loc);
    }
    if (a == INT64_MIN && b == -1) {
        auk_panic_overflow(loc, "/");
    }
    return a / b;
}

AUK_API int64_t auk_mod(int64_t a, int64_t b, const char *loc) {
    if (b == 0) {
        auk_panic_div_zero(loc);
    }
    if (b == -1) {
        return 0;
    }
    return a % b;
}

AUK_API int64_t auk_neg(int64_t a, const char *loc) {
    if (a == INT64_MIN) {
        auk_panic_overflow(loc, "-");
    }
    return -a;
}

AUK_API int64_t auk_wadd(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a + (uint64_t)b);
}

AUK_API int64_t auk_wsub(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a - (uint64_t)b);
}

AUK_API int64_t auk_wmul(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a * (uint64_t)b);
}

static _Noreturn void bad_shift(int64_t n, const char *loc) {
    char buf[21];
    auk__panic3(loc, "shift amount ", dec(n, buf), " is outside 0..63");
}

AUK_API int64_t auk_shl(int64_t a, int64_t n, const char *loc) {
    if ((uint64_t)n > 63) {
        bad_shift(n, loc);
    }
    return (int64_t)((uint64_t)a << n);
}

AUK_API int64_t auk_shr(int64_t a, int64_t n, const char *loc) {
    if ((uint64_t)n > 63) {
        bad_shift(n, loc);
    }
    return a >> n;
}

AUK_API int auk_int_cmp(int64_t a, int64_t b) {
    return (a > b) - (a < b);
}

AUK_API int64_t auk_pow(int64_t a, int64_t b, const char *loc) {
    if (b < 0) {
        auk__panic3(loc, "negative exponent in `**`", NULL, NULL);
    }
    int64_t r = 1;
    while (b > 0) {
        if ((b & 1) != 0 && __builtin_mul_overflow(r, a, &r)) {
            auk_panic_overflow(loc, "**");
        }
        b >>= 1;
        if (b > 0 && __builtin_mul_overflow(a, a, &a)) {
            auk_panic_overflow(loc, "**");
        }
    }
    return r;
}

AUK_API int64_t auk_int_abs(int64_t a, const char *loc) {
    if (a == INT64_MIN) {
        auk_panic_overflow(loc, "abs");
    }
    return a < 0 ? -a : a;
}

AUK_API double auk_fpow(double a, double b) {
    return pow(a, b);
}

AUK_API double auk_fmod(double a, double b) {
    return fmod(a, b);
}

AUK_API double auk_fsqrt(double a) {
    return sqrt(a);
}

AUK_API double auk_fabs(double a) {
    return fabs(a);
}

AUK_API double auk_ffloor(double a) {
    return floor(a);
}

AUK_API double auk_fceil(double a) {
    return ceil(a);
}

AUK_API double auk_fround(double a) {
    return round(a);
}

AUK_API double auk_fsin(double a) {
    return sin(a);
}

AUK_API double auk_fcos(double a) {
    return cos(a);
}

AUK_API double auk_ftan(double a) {
    return tan(a);
}

AUK_API double auk_fasin(double a) {
    return asin(a);
}

AUK_API double auk_facos(double a) {
    return acos(a);
}

AUK_API double auk_fatan(double a) {
    return atan(a);
}

AUK_API double auk_fexp(double a) {
    return exp(a);
}

AUK_API double auk_fln(double a) {
    return log(a);
}

AUK_API double auk_flog10(double a) {
    return log10(a);
}

AUK_API double auk_flog2(double a) {
    return log2(a);
}

AUK_API double auk_fatan2(double y, double x) {
    return atan2(y, x);
}

/* The IEEE 754 bits of a float, as an int. */
AUK_API int64_t auk_fbits(double a) {
    int64_t n;
    memcpy(&n, &a, 8);
    return n;
}

AUK_API double auk_ffrom_bits(int64_t n) {
    double a;
    memcpy(&a, &n, 8);
    return a;
}

/* The bits of a float rounded to single precision (0 to 2^32 - 1). */
AUK_API int64_t auk_fbits32(double a) {
    float f = (float)a;
    uint32_t n;
    memcpy(&n, &f, 4);
    return (int64_t)n;
}

/* A single-precision float from its low 32 bits. */
AUK_API double auk_ffrom_bits32(int64_t n) {
    uint32_t u = (uint32_t)n;
    float f;
    memcpy(&f, &u, 4);
    return (double)f;
}

AUK_API int64_t auk_float_to_int(double x, const char *loc) {
    if (isnan(x)) {
        auk__panic3(loc, "int(NaN)", NULL, NULL);
    }
    if (!(x >= -9223372036854775808.0 && x < 9223372036854775808.0)) {
        char g[64];
        snprintf(g, sizeof g, "%g", x);
        auk__panic3(loc, "int(", g, ") is out of range");
    }
    return (int64_t)x;
}

AUK_API int auk_float_cmp(double a, double b) {
    if (isnan(a) || isnan(b)) {
        return (int)isnan(a) - (int)isnan(b);
    }
    return (a > b) - (a < b);
}

/* ---- hashing ----------------------------------------------------------------------------- */

AUK_API uint64_t auk_hash_bytes(const void *p, size_t n) {
    const uint8_t *b = p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 1099511628211ULL;
    }
    return auk_hash_int((int64_t)h);
}

AUK_API uint64_t auk_hash_int(int64_t x) {
    uint64_t z = (uint64_t)x + 0x9e3779b97f4a7c15ULL;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

AUK_API uint64_t auk_hash_combine(uint64_t h, uint64_t x) {
    return auk_hash_int((int64_t)(h * 31 + x));
}

/* ---- scalar element ops ------------------------------------------------------------------ */

static bool int_eq(const void *a, const void *b) {
    return *(const int64_t *)a == *(const int64_t *)b;
}

static int int_cmp(const void *a, const void *b) {
    return auk_int_cmp(*(const int64_t *)a, *(const int64_t *)b);
}

static uint64_t int_hash(const void *a) {
    return auk_hash_int(*(const int64_t *)a);
}

static AukStr *int_show(const void *a) {
    return auk_str_from_int(*(const int64_t *)a);
}

AUK_API const AukElemOps auk_ops_int = {8, NULL, NULL, int_eq, int_cmp, int_hash, int_show, NULL};

static bool float_eq(const void *a, const void *b) {
    return *(const double *)a == *(const double *)b;
}

static int float_cmp(const void *a, const void *b) {
    return auk_float_cmp(*(const double *)a, *(const double *)b);
}

static uint64_t float_hash(const void *a) {
    double d = *(const double *)a;
    if (d == 0.0) {
        d = 0.0; /* -0.0 == 0.0 */
    }
    return auk_hash_int(auk_fbits(d));
}

static AukStr *float_show(const void *a) {
    return auk_str_from_float(*(const double *)a);
}

AUK_API const AukElemOps auk_ops_float = {8, NULL, NULL, float_eq, float_cmp, float_hash, float_show, NULL};

static bool bool_eq(const void *a, const void *b) {
    return *(const bool *)a == *(const bool *)b;
}

static int bool_cmp(const void *a, const void *b) {
    return (int)*(const bool *)a - (int)*(const bool *)b;
}

static uint64_t bool_hash(const void *a) {
    return auk_hash_int(*(const bool *)a ? 1 : 0);
}

static AukStr *bool_show(const void *a) {
    return auk_str_from_bool(*(const bool *)a);
}

AUK_API const AukElemOps auk_ops_bool = {1, NULL, NULL, bool_eq, bool_cmp, bool_hash, bool_show, NULL};

static bool char_eq(const void *a, const void *b) {
    return *(const uint32_t *)a == *(const uint32_t *)b;
}

static int char_cmp(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a;
    uint32_t y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

static uint64_t char_hash(const void *a) {
    return auk_hash_int(*(const uint32_t *)a);
}

static AukStr *char_show(const void *a) {
    return auk_char_quote(*(const uint32_t *)a);
}

AUK_API const AukElemOps auk_ops_char = {4, NULL, NULL, char_eq, char_cmp, char_hash, char_show, NULL};

static bool unit_eq(const void *a, const void *b) {
    (void)a;
    (void)b;
    return true;
}

static int unit_cmp(const void *a, const void *b) {
    (void)a;
    (void)b;
    return 0;
}

static uint64_t unit_hash(const void *a) {
    (void)a;
    return 0;
}

static AukStr *unit_show(const void *a) {
    (void)a;
    return auk_str_lit("()");
}

AUK_API const AukElemOps auk_ops_unit = {1, NULL, NULL, unit_eq, unit_cmp, unit_hash, unit_show, NULL};

void auk__ptr_retain(void *p) {
    auk_retain(*(void **)p);
}

void auk__ptr_release(void *p) {
    auk_release(*(void **)p);
}

static bool str_eq(const void *a, const void *b) {
    return auk_str_eq(*(AukStr *const *)a, *(AukStr *const *)b);
}

static int str_cmp(const void *a, const void *b) {
    return auk_str_cmp(*(AukStr *const *)a, *(AukStr *const *)b);
}

static uint64_t str_hash(const void *a) {
    return auk_str_hash(*(AukStr *const *)a);
}

static AukStr *str_show(const void *a) {
    return auk_str_quote(*(AukStr *const *)a);
}

AUK_API const AukElemOps auk_ops_str = {
    8, auk__ptr_retain, auk__ptr_release, str_eq, str_cmp, str_hash, str_show, auk__str_copy_elem,
};

static bool arr_eq(const void *a, const void *b) {
    return auk_arr_eq(*(AukArr *const *)a, *(AukArr *const *)b);
}

static int arr_cmp(const void *a, const void *b) {
    return auk_arr_cmp(*(AukArr *const *)a, *(AukArr *const *)b);
}

static uint64_t arr_hash(const void *a) {
    return auk_arr_hash(*(AukArr *const *)a);
}

static AukStr *arr_show(const void *a) {
    return auk_arr_show(*(AukArr *const *)a);
}

AUK_API const AukElemOps auk_ops_arr = {
    8, auk__ptr_retain, auk__ptr_release, arr_eq, arr_cmp, arr_hash, arr_show, auk__arr_copy_elem,
};

static bool map_eq(const void *a, const void *b) {
    return auk_map_eq(*(AukMap *const *)a, *(AukMap *const *)b);
}

static AukStr *map_show(const void *a) {
    return auk_map_show(*(AukMap *const *)a);
}

AUK_API const AukElemOps auk_ops_map = {
    8, auk__ptr_retain, auk__ptr_release, map_eq, NULL, NULL, map_show, auk__map_copy_elem,
};

static AukStr *err_show(const void *a) {
    return auk_err_show(*(AukErr *const *)a);
}

AUK_API const AukElemOps auk_ops_err = {
    8, auk__ptr_retain, auk__ptr_release, NULL, NULL, NULL, err_show, auk__err_copy_elem,
};

AUK_API const AukElemOps auk_ops_obj = {
    8, auk__ptr_retain, auk__ptr_release, NULL, NULL, NULL, NULL, auk__obj_copy_elem,
};

AUK_API const AukElemOps auk_ops_task = {
    8, auk__ptr_retain, auk__ptr_release, NULL, NULL, NULL, NULL, auk__handle_copy_elem,
};

static void closure_retain(void *p) {
    auk_retain(((AukClosure *)p)->env);
}

static void closure_release(void *p) {
    auk_release(((AukClosure *)p)->env);
}

AUK_API const AukElemOps auk_ops_closure = {
    16, closure_retain, closure_release, NULL, NULL, NULL, NULL, auk__closure_copy_elem,
};

AUK_API void auk_closure_retain(AukClosure c) {
    auk_retain(c.env);
}

AUK_API void auk_closure_release(AukClosure c) {
    auk_release(c.env);
}
