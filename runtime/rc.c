/* Refcounting, allocation, panics, arithmetic, hashing and scalar ops. */
#include "duck_internal.h"

#include <math.h>
#include <stdarg.h>
#include <unistd.h>

/* ---- allocation & leak counter --------------------------------------- */

static _Atomic int64_t live_objects;

int64_t duck_live_objects(void) { return atomic_load(&live_objects); }

static _Noreturn void oom(void) {
    fputs("panic: out of memory\n", stderr);
    _exit(101);
}

void *duck__xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) oom();
    return p;
}
void *duck__xcalloc(size_t n, size_t sz) {
    void *p = calloc(n ? n : 1, sz ? sz : 1);
    if (!p) oom();
    return p;
}
void *duck__xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) oom();
    return q;
}

void *duck__alloc(size_t size, uint32_t kind) {
    DuckHeader *h = duck__xcalloc(1, size);
    atomic_init(&h->rc, 1);
    h->kind = kind;
#ifndef DUCK_NO_LEAK_COUNTER
    atomic_fetch_add_explicit(&live_objects, 1, memory_order_relaxed);
#endif
    return h;
}

void duck__free_obj(void *p) {
#ifndef DUCK_NO_LEAK_COUNTER
    atomic_fetch_sub_explicit(&live_objects, 1, memory_order_relaxed);
#endif
    free(p);
}

void duck__make_immortal(void *p) {
    if (!p || atomic_load(&((DuckHeader *)p)->rc) < 0) return;
    atomic_store(&((DuckHeader *)p)->rc, INT64_MIN / 2);
#ifndef DUCK_NO_LEAK_COUNTER
    atomic_fetch_sub_explicit(&live_objects, 1, memory_order_relaxed);
#endif
}

void duck_make_immortal(void *p) { duck__make_immortal(p); }

static void (*g_cleanup)(void);
void duck_set_cleanup(void (*fn)(void)) { g_cleanup = fn; }

int64_t duck_leak_check(void) {
    if (!getenv("DUCK_LEAK_CHECK")) return 0;
    if (g_cleanup) g_cleanup();
    int64_t n = duck_live_objects();
    if (n != 0) {
        fflush(stdout);
        fprintf(stderr, "leak: %lld runtime object(s) still live at exit\n", (long long)n);
        fflush(stderr);
    }
    return n;
}

void *duck_retain(void *p) {
    if (!p) return p;
    DuckHeader *h = p;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) < 0) return p;
    atomic_fetch_add_explicit(&h->rc, 1, memory_order_relaxed);
    return p;
}

void duck_release(void *p) {
    if (!p) return;
    DuckHeader *h = p;
    if (atomic_load_explicit(&h->rc, memory_order_relaxed) < 0) return;
    if (atomic_fetch_sub_explicit(&h->rc, 1, memory_order_release) != 1) return;
    atomic_thread_fence(memory_order_acquire);
    switch (h->kind) {
    case DUCK_K_STR: duck__str_free(p); break;
    case DUCK_K_ARR: duck__arr_free(p); break;
    case DUCK_K_MAP: duck__map_free(p); break;
    case DUCK_K_ERR: duck__err_free(p); break;
    case DUCK_K_TASK: duck__task_free(p); break;
    case DUCK_K_CONN: duck__conn_free(p); break;
    case DUCK_K_LISTENER: duck__listener_free(p); break;
    case DUCK_K_OBJ: {
        DuckObj *o = p;
        if (o->drop) o->drop(o);
        duck__free_obj(o);
        break;
    }
    default:
        duck_panic("runtime", "release of an object with unknown kind %u", h->kind);
    }
}

int64_t duck_refcount(const void *p) {
    if (!p) return 0;
    return atomic_load(&((DuckHeader *)p)->rc);
}

void *duck_obj_alloc(size_t size, void (*drop)(DuckObj *self)) {
    if (size < sizeof(DuckObj)) size = sizeof(DuckObj);
    DuckObj *o = duck__alloc(size, DUCK_K_OBJ);
    o->drop = drop;
    return o;
}

/* ---- panics ---------------------------------------------------------- */

void duck_panic(const char *loc, const char *fmt, ...) {
    fflush(stdout);
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "panic: %s\n  at %s\n", buf, loc ? loc : "<unknown>");
    fflush(stderr);
    duck__trace_panic(loc, buf);
    /* _exit: don't run atexit handlers (other threads may still be busy). */
    _exit(101);
}

void duck_panic_overflow(const char *loc, const char *op) {
    duck_panic(loc, "integer overflow in `%s`", op);
}
void duck_panic_div_zero(const char *loc) { duck_panic(loc, "division by zero"); }

void duck_unwrap_none(const char *loc) { duck_panic(loc, "unwrapped `none`"); }

void duck_unwrap_err(const char *loc, DuckErr *e) {
    DuckStr *s = duck_err_show(e);
    duck_panic(loc, "unwrapped an error: %s", duck_str_cstr(s));
}

/* ---- arithmetic ------------------------------------------------------ */

int64_t duck_pow(int64_t a, int64_t b, const char *loc) {
    if (b < 0) duck_panic(loc, "negative exponent in `**`");
    int64_t r = 1;
    while (b > 0) {
        if (b & 1) {
            if (__builtin_mul_overflow(r, a, &r)) duck_panic_overflow(loc, "**");
        }
        b >>= 1;
        if (b > 0 && __builtin_mul_overflow(a, a, &a)) duck_panic_overflow(loc, "**");
    }
    return r;
}

int64_t duck_int_abs(int64_t a, const char *loc) {
    if (a == INT64_MIN) duck_panic_overflow(loc, "abs");
    return a < 0 ? -a : a;
}

double duck_fpow(double a, double b) { return pow(a, b); }
double duck_fmod(double a, double b) { return fmod(a, b); }
double duck_fsqrt(double a) { return sqrt(a); }
double duck_fabs(double a) { return fabs(a); }
double duck_ffloor(double a) { return floor(a); }
double duck_fceil(double a) { return ceil(a); }
double duck_fround(double a) { return round(a); }

int64_t duck_float_to_int(double x, const char *loc) {
    if (isnan(x)) duck_panic(loc, "int(NaN)");
    /* valid range is [-2^63, 2^63) */
    if (!(x >= -9223372036854775808.0 && x < 9223372036854775808.0))
        duck_panic(loc, "int(%g) is out of range", x);
    return (int64_t)x;
}

int duck_float_cmp(double a, double b) {
    if (isnan(a) || isnan(b)) return isnan(a) - isnan(b);
    return (a > b) - (a < b);
}

/* ---- hashing --------------------------------------------------------- */

uint64_t duck_hash_bytes(const void *p, size_t n) {
    const unsigned char *b = p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 1099511628211ULL;
    }
    return duck_hash_int((int64_t)h);
}

uint64_t duck_hash_int(int64_t x) {
    uint64_t z = (uint64_t)x + 0x9e3779b97f4a7c15ULL;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

uint64_t duck_hash_combine(uint64_t h, uint64_t x) {
    return duck_hash_int((int64_t)(h * 31 + x));
}

/* ---- scalar element ops ---------------------------------------------- */

static bool int_eq(const void *a, const void *b) { return *(const int64_t *)a == *(const int64_t *)b; }
static int int_cmp(const void *a, const void *b) { return duck_int_cmp(*(const int64_t *)a, *(const int64_t *)b); }
static uint64_t int_hash(const void *a) { return duck_hash_int(*(const int64_t *)a); }
static DuckStr *int_show(const void *a) { return duck_str_from_int(*(const int64_t *)a); }
const DuckElemOps duck_ops_int = {sizeof(int64_t), NULL, NULL, int_eq, int_cmp, int_hash, int_show};

static bool float_eq(const void *a, const void *b) { return *(const double *)a == *(const double *)b; }
static int float_cmp(const void *a, const void *b) { return duck_float_cmp(*(const double *)a, *(const double *)b); }
static uint64_t float_hash(const void *a) {
    double d = *(const double *)a;
    if (d == 0) d = 0; /* -0.0 == 0.0 */
    int64_t bits;
    memcpy(&bits, &d, sizeof bits);
    return duck_hash_int(bits);
}
static DuckStr *float_show(const void *a) { return duck_str_from_float(*(const double *)a); }
const DuckElemOps duck_ops_float = {sizeof(double), NULL, NULL, float_eq, float_cmp, float_hash, float_show};

static bool bool_eq(const void *a, const void *b) { return *(const bool *)a == *(const bool *)b; }
static int bool_cmp(const void *a, const void *b) { return (int)*(const bool *)a - (int)*(const bool *)b; }
static uint64_t bool_hash(const void *a) { return duck_hash_int(*(const bool *)a); }
static DuckStr *bool_show(const void *a) { return duck_str_from_bool(*(const bool *)a); }
const DuckElemOps duck_ops_bool = {sizeof(bool), NULL, NULL, bool_eq, bool_cmp, bool_hash, bool_show};

static bool char_eq(const void *a, const void *b) { return *(const uint32_t *)a == *(const uint32_t *)b; }
static int char_cmp(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}
static uint64_t char_hash(const void *a) { return duck_hash_int(*(const uint32_t *)a); }
static DuckStr *char_show(const void *a) { return duck_char_quote(*(const uint32_t *)a); }
const DuckElemOps duck_ops_char = {sizeof(uint32_t), NULL, NULL, char_eq, char_cmp, char_hash, char_show};

static bool unit_eq(const void *a, const void *b) { (void)a, (void)b; return true; }
static int unit_cmp(const void *a, const void *b) { (void)a, (void)b; return 0; }
static uint64_t unit_hash(const void *a) { (void)a; return 0; }
static DuckStr *unit_show(const void *a) { (void)a; return duck_str_lit("()"); }
const DuckElemOps duck_ops_unit = {sizeof(DuckUnit), NULL, NULL, unit_eq, unit_cmp, unit_hash, unit_show};

static void ptr_retain(void *p) { duck_retain(*(void **)p); }
static void ptr_release(void *p) { duck_release(*(void **)p); }

static bool str_eq(const void *a, const void *b) { return duck_str_eq(*(DuckStr *const *)a, *(DuckStr *const *)b); }
static int str_cmp(const void *a, const void *b) { return duck_str_cmp(*(DuckStr *const *)a, *(DuckStr *const *)b); }
static uint64_t str_hash(const void *a) { return duck_str_hash(*(DuckStr *const *)a); }
static DuckStr *str_show(const void *a) { return duck_str_quote(*(DuckStr *const *)a); }
const DuckElemOps duck_ops_str = {sizeof(DuckStr *), ptr_retain, ptr_release, str_eq, str_cmp, str_hash, str_show};

static bool arr_eq(const void *a, const void *b) { return duck_arr_eq(*(DuckArr *const *)a, *(DuckArr *const *)b); }
static int arr_cmp(const void *a, const void *b) { return duck_arr_cmp(*(DuckArr *const *)a, *(DuckArr *const *)b); }
static uint64_t arr_hash(const void *a) { return duck_arr_hash(*(DuckArr *const *)a); }
static DuckStr *arr_show(const void *a) { return duck_arr_show(*(DuckArr *const *)a); }
const DuckElemOps duck_ops_arr = {sizeof(DuckArr *), ptr_retain, ptr_release, arr_eq, arr_cmp, arr_hash, arr_show};

static bool map_eq(const void *a, const void *b) { return duck_map_eq(*(DuckMap *const *)a, *(DuckMap *const *)b); }
static DuckStr *map_show(const void *a) { return duck_map_show(*(DuckMap *const *)a); }
const DuckElemOps duck_ops_map = {sizeof(DuckMap *), ptr_retain, ptr_release, map_eq, NULL, NULL, map_show};

static DuckStr *err_show(const void *a) { return duck_err_show(*(DuckErr *const *)a); }
const DuckElemOps duck_ops_err = {sizeof(DuckErr *), ptr_retain, ptr_release, NULL, NULL, NULL, err_show};

const DuckElemOps duck_ops_obj = {sizeof(DuckObj *), ptr_retain, ptr_release, NULL, NULL, NULL, NULL};
const DuckElemOps duck_ops_task = {sizeof(DuckTask *), ptr_retain, ptr_release, NULL, NULL, NULL, NULL};

static void closure_retain(void *p) { duck_retain(((DuckClosure *)p)->env); }
static void closure_release(void *p) { duck_release(((DuckClosure *)p)->env); }
const DuckElemOps duck_ops_closure = {sizeof(DuckClosure), closure_retain, closure_release, NULL, NULL, NULL, NULL};
