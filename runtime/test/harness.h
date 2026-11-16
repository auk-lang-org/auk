/* Minimal unit-test harness for the runtime's C tests.
 *
 * TEST(name) { ... } registers a test (via a constructor). Each test runs
 * in-process; afterwards the harness checks that duck_live_objects() is back
 * to its starting value (leak check). CHECK failures longjmp out of the test.
 * th_child() forks to observe panics/exits. */
#ifndef DUCK_TEST_HARNESS_H
#define DUCK_TEST_HARNESS_H

#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include "duck.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*th_fn)(void);
void th_register(const char *name, th_fn fn);
_Noreturn void th_fail(const char *file, int line, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

#define TEST(name)                                                                     \
    static void name(void);                                                            \
    __attribute__((constructor)) static void th_reg_##name(void) { th_register(#name, name); } \
    static void name(void)

#define CHECK(cond)                                                \
    do {                                                           \
        if (!(cond)) th_fail(__FILE__, __LINE__, "CHECK(%s)", #cond); \
    } while (0)

#define CHECK_INT(a, b)                                                                                       \
    do {                                                                                                      \
        long long th_a_ = (long long)(a), th_b_ = (long long)(b);                                             \
        if (th_a_ != th_b_) th_fail(__FILE__, __LINE__, "%s == %s: %lld != %lld", #a, #b, th_a_, th_b_); \
    } while (0)

/* Compare an OWNED DuckStr* against a C string, then release it. */
#define CHECK_STR(s, lit) th_check_str(__FILE__, __LINE__, #s, (s), (lit))
void th_check_str(const char *file, int line, const char *expr, DuckStr *s, const char *want);

/* Owned str from a literal (shorthand). */
#define S(lit) duck_str_lit(lit)

/* Run fn in a forked child. Returns the exit code (or 128+signal) and
 * captures up to outn-1 bytes of its combined stdout/stderr into out. */
int th_child(void (*fn)(void *), void *ctx, char *out, size_t outn);

/* Assert that fn (a void(void*) function) panics with exit code 101 and
 * that the output contains `needle`. */
#define EXPECT_PANIC(fn, ctx, needle) th_expect_panic(__FILE__, __LINE__, (fn), (ctx), (needle))
void th_expect_panic(const char *file, int line, void (*fn)(void *), void *ctx, const char *needle);

/* A scratch directory unique to this test run (created on demand). */
const char *th_tmpdir(void);

#endif
