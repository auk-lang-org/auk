/* A small harness for the runtime's unit tests (the port of runtime/tests/common/mod.rs).
 *
 * Every test is a `void f(void)` listed in its file's TestCase table. test_main.c runs them in
 * order, one at a time, in this process, and checks that auk_live_objects() is back to its
 * starting value after each one (the leak check). A failed CHECK prints where and why and ends
 * the test (longjmp back to the runner). child() / expect_panic() fork to observe panics, exits
 * and output; a failed CHECK inside such a child makes it exit 98. */
#ifndef AUK_TEST_H
#define AUK_TEST_H

#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

typedef void (*TestFn)(void);

typedef struct TestCase {
    const char *name;
    TestFn fn;
} TestCase;

/* The tables (one per file, ended by {NULL, NULL}). */
extern const TestCase arr_tests[];
extern const TestCase conc_tests[];
extern const TestCase core_tests[];
extern const TestCase io_tests[];
extern const TestCase map_tests[];
extern const TestCase net_tests_list[];
extern const TestCase str_tests[];

/* ---- failing ------------------------------------------------------------------------------ */

/* Report a failed check at file:line and end the test (or the child process). */
_Noreturn void t_fail(const char *file, int line, const char *fmt, ...);

#define CHECK(c)                                                         \
    do {                                                                 \
        if (!(c)) t_fail(__FILE__, __LINE__, "check failed: %s", #c);    \
    } while (0)

/* Two int64 values must be equal. */
#define CHECK_INT(got, want)                                                                    \
    do {                                                                                        \
        int64_t g_ = (int64_t)(got), w_ = (int64_t)(want);                                      \
        if (g_ != w_)                                                                           \
            t_fail(__FILE__, __LINE__, "%s == %s: got %lld, want %lld", #got, #want,            \
                   (long long)g_, (long long)w_);                                               \
    } while (0)

/* Two C strings must be equal. */
#define CHECK_TEXT(got, want) t_check_text(__FILE__, __LINE__, (got), (want))
/* got must contain needle. */
#define CHECK_HAS(got, needle) t_check_has(__FILE__, __LINE__, (got), (needle))
/* Compare an OWNED str with want (bytes and byte length), then release it. */
#define CHECK_STR(owned, want) t_check_str(__FILE__, __LINE__, (owned), (want))

void t_check_text(const char *file, int line, const char *got, const char *want);
void t_check_has(const char *file, int line, const char *got, const char *needle);
void t_check_str(const char *file, int line, AukStr *owned, const char *want);

/* ---- scratch memory --------------------------------------------------------------------- */

/* Keep a malloc'd pointer until the current test ends (then it is freed). Returns p. */
char *t_keep(char *p);
/* A kept copy of n bytes (NUL-terminated). */
char *t_copy(const char *p, size_t n);
/* A kept, printf-formatted string. */
char *t_fmt(const char *fmt, ...);
/* Free everything kept (the runner calls this after each test). */
void t_free_kept(void);

/* ---- runtime helpers -------------------------------------------------------------------- */

/* An owned str from text (auk_str_lit). */
AukStr *s(const char *text);
/* Release / retain any runtime object (retain returns it). */
void rel(void *p);
void *ret(void *p);
/* The text of a (borrowed) str (NULL is ""). */
const char *text(const AukStr *p);
/* A new error with the message msg (owned). */
AukErr *err_msg(const char *msg);
/* The shown text of an owned error (kept), releasing the error. */
char *err_text(AukErr *e);
/* An int array of n values. */
AukArr *ints(const int64_t *xs, int64_t n);
/* The elements of an int array (NULL when empty). */
const int64_t *int_elems(const AukArr *a);
/* Write text to the C library's stdout (what the runtime's own output goes through). */
void cprint(const char *t);
/* Append text to a string builder. */
void sb_push(AukStrBuf *b, const char *t);

/* Typed element read and rvalue push. */
#define AT(T, a, i) (*(T *)auk_arr_at((a), (i), "t"))
#define PUSH(T, pa, v)            \
    do {                          \
        T tmp_ = (v);             \
        auk_arr_push((pa), &tmp_); \
    } while (0)

/* ---- child processes ------------------------------------------------------------------ */

typedef void (*ChildFn)(void *ctx);

/* Run f(ctx) in a forked child with stdout and stderr both going into one pipe; returns the
 * exit code (or 128+signal) and sets *out to the captured output (kept). The child _exit(0)s
 * after f (a failed CHECK in the child exits 98). */
int child(ChildFn f, void *ctx, char **out);

/* f(ctx) must panic (exit 101, `panic: ` in the output) with output containing needle. */
#define EXPECT_PANIC(f, ctx, needle) t_expect_panic(__FILE__, __LINE__, (f), (ctx), (needle))
void t_expect_panic(const char *file, int line, ChildFn f, void *ctx, const char *needle);

/* Are we in a child made by child()? */
extern bool t_in_child;

/* ---- scratch directories ------------------------------------------------------------------ */

/* A fresh scratch directory (kept path), removed with everything in it when the test ends. */
char *tmpdir_new(void);
/* An owned str naming name inside dir. */
AukStr *tmpdir_path(const char *dir, const char *name);

/* ---- network ------------------------------------------------------------------------------- */

/* Should tests reach real hosts? AUK_NET_TESTS=1/0 decides; unset, probe example.com:443 with
 * a 3s connect timeout. */
bool net_tests(void);

#endif
