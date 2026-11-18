/* A C library for tests/ffi.rs: one function per marshalling case of user-level FFI
 * (docs/ffi-plan.md). Built into a shared library by the test and named by path in the test
 * project's raft.toml `[link] libs`. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* integers: returned as received, so the test sees truncation going in and extension coming out */
int8_t t_i8(int8_t x) { return x; }
uint8_t t_u8(uint8_t x) { return x; }
int16_t t_i16(int16_t x) { return x; }
uint16_t t_u16(uint16_t x) { return x; }
int32_t t_i32(int32_t x) { return x; }
uint32_t t_u32(uint32_t x) { return x; }
uint64_t t_u64(uint64_t x) { return x; }
long long t_add(long long a, long long b) { return a + b; }
char t_next_char(char c) { return (char)(c + 1); }

bool t_not(bool b) { return !b; }
float t_half(float x) { return x / 2; }
double t_mix(int8_t a, float b, double c, uint16_t d, bool e) { return a + b + c + d + (e ? 1000 : 0); }

/* strings */
static char greeting[64];
const char *t_greet(const char *name) {
    snprintf(greeting, sizeof greeting, "hi %s", name);
    return greeting;
}
const char *t_null_str(void) { return NULL; }
int t_is_null(const char *s) { return s == NULL; }

/* owned strings and their disposer */
static int frees;
char *t_dup(const char *s) { return strdup(s); }
void t_free(char *p) {
    if (p != NULL) {
        frees++;
    }
    free(p);
}
int t_frees(void) { return frees; }

/* out-parameters */
int t_out(int x, int *twice, char **msg) {
    *twice = x * 2;
    *msg = x < 0 ? NULL : strdup("ok");
    return 1;
}
void t_scale(double *x, float *y) {
    *x *= 3;
    *y *= 3;
}
void t_flip(bool *b) { *b = !*b; }

/* opaque handles */
struct thing {
    int id;
};
struct thing *t_new(int id) {
    struct thing *t = malloc(sizeof *t);
    t->id = id;
    return t;
}
int t_id(const struct thing *t) { return t->id; }
void t_del(struct thing *t) { free(t); }
int t_make(int id, struct thing **out) {
    *out = id < 0 ? NULL : t_new(id);
    return *out != NULL;
}
struct thing *t_maybe(int id) { return id < 0 ? NULL : t_new(id); }
int t_id_or(const struct thing *t, int dflt) { return t == NULL ? dflt : t->id; }

/* arrays in and in/out */
int t_sum_ids(struct thing *const *ts, unsigned n) {
    int s = 0;
    for (unsigned i = 0; i < n; i++) {
        s += ts[i]->id;
    }
    return s;
}
void t_fill(int32_t *xs, size_t n) {
    for (size_t i = 0; i < n; i++) {
        xs[i] = xs[i] * 10 - (int32_t)i;
    }
}
double t_sumf(const float *xs, size_t n) {
    double s = 0;
    for (size_t i = 0; i < n; i++) {
        s += xs[i];
    }
    return s;
}
void t_halve(float *xs, size_t n) {
    for (size_t i = 0; i < n; i++) {
        xs[i] /= 2;
    }
}
long long t_sum_i64(const int64_t *xs, size_t n) {
    long long s = 0;
    for (size_t i = 0; i < n; i++) {
        s += xs[i];
    }
    return s;
}
int t_count_true(const bool *bs, size_t n) {
    int c = 0;
    for (size_t i = 0; i < n; i++) {
        c += bs[i];
    }
    return c;
}
void t_reverse_handles(struct thing **ts, size_t n) {
    for (size_t i = 0; i < n / 2; i++) {
        struct thing *t = ts[i];
        ts[i] = ts[n - 1 - i];
        ts[n - 1 - i] = t;
    }
}

/* byte buffers */
unsigned t_checksum(const void *buf, size_t n) {
    const uint8_t *b = buf;
    unsigned s = 0;
    for (size_t i = 0; i < n; i++) {
        s = s * 31 + b[i];
    }
    return s;
}
void t_bytes_out(uint8_t *buf, size_t n) {
    for (size_t i = 0; i < n; i++) {
        buf[i] = (uint8_t)(250 + i);
    }
}
static uint8_t blob[4] = {1, 2, 255, 0};
const void *t_blob(size_t *n) {
    *n = sizeof blob;
    return blob;
}

/* function pointers, called from Auk through `"T (*)(...)"` prototypes */
static double t_scale3(double x, int32_t k) { return x * k; }
void *t_fn(int which) {
    switch (which) {
    case 0: return (void *)t_add;
    case 1: return (void *)t_scale3;
    case 2: return (void *)t_greet;
    default: return (void *)0;
    }
}
