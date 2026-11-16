/* Private helpers shared by the runtime's .c files. Not part of the ABI. */
#ifndef DUCK_INTERNAL_H
#define DUCK_INTERNAL_H

/* POSIX + platform extras (must precede every system header). */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif

#include "duck.h"

#include <stdio.h>
#include <stdlib.h>

/* Allocate a zeroed heap object with rc = 1 (counted as live). */
void *duck__alloc(size_t size, uint32_t kind);
/* Make p (and nothing else) immortal: retain/release become no-ops and it
 * no longer counts as live. For process-lifetime globals. */
void duck__make_immortal(void *p);
/* Free the object memory itself (and update the live counter). */
void duck__free_obj(void *p);

void *duck__xmalloc(size_t n);
void *duck__xcalloc(size_t n, size_t sz);
void *duck__xrealloc(void *p, size_t n);

/* Per-kind destructors: release children, then duck__free_obj. */
void duck__str_free(DuckStr *s);
void duck__arr_free(DuckArr *a);
void duck__map_free(DuckMap *m);
void duck__err_free(DuckErr *e);
void duck__task_free(DuckTask *t);
void duck__conn_free(DuckConn *c);
void duck__listener_free(DuckListener *l);

/* TLS sessions (tls.c); core.c's Conn functions dispatch here when c->tls is set.
 * `buf` holds raw bytes. duck__tls_free closes the session and frees it. */
DuckRes_arr duck__tls_read(void *tls, int64_t max);
DuckRes_unit duck__tls_write(void *tls, const unsigned char *buf, int64_t n);
void duck__tls_free(void *tls);

/* A string from bytes already known to be valid UTF-8. */
DuckStr *duck__str_new(const char *p, int64_t n);
/* A string whose metadata is already known. */
DuckStr *duck__str_raw(const char *p, int64_t n, int64_t chars, bool ascii);
/* Byte offset of char index i (0 <= i <= len_chars). */
int64_t duck__str_byte_offset(const DuckStr *s, int64_t i);
/* Decode one UTF-8 char at p (valid input); stores its length. */
uint32_t duck__utf8_decode(const char *p, int *len);

/* Shortest round-trip float text into buf (>= 40 bytes). */
void duck__fmt_float_shortest(double v, char *buf, size_t n);

/* Errors from errno: "<what>: <strerror>" with code errno. */
DuckErr *duck__err_errno(const char *what, const DuckStr *subject, int err);

/* Execution traces (trace.c). */
/* While the tracer shows a value: the bytes string builders may still append (then appends
 * are dropped and list/map/str shows stop early), so showing a huge value costs O(budget).
 * -1 = no budget (always, unless tracing). */
extern _Thread_local int64_t duck__show_left;
static inline bool duck__show_exhausted(void) { return DUCK_UNLIKELY(duck_trace_live) && duck__show_left == 0; }
/* Count n appended bytes against the budget; false = drop them. */
static inline bool duck__show_take(int64_t n) {
    if (!DUCK_UNLIKELY(duck_trace_live) || duck__show_left < 0) return true;
    if (duck__show_left == 0) return false;
    duck__show_left = n >= duck__show_left ? 0 : duck__show_left - n;
    return true;
}
void duck__trace_peek(const char *loc, const char *src_text, const DuckStr *shown);
/* A panic: records it and writes out the trace (the process is about to _exit). */
void duck__trace_panic(const char *loc, const char *msg);
/* Write out everything recorded (before an _exit). */
void duck__trace_flush(void);
/* The test runner: `-` mode (each failing test prints its last events) or the directory. */
bool duck__trace_tail_mode(void);
const char *duck__trace_dir(void);
/* In a test's child: start its trace (tail_path: the file the tail is dumped to). */
void duck__trace_test_begin(const char *name, const char *tail_path);
/* In the runner, after a test: append its {"ev":"test"} event. */
void duck__trace_test_end(const char *name, bool ok, const char *tail_path);

#endif
