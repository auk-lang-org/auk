/* Recovery points for `catch` and task threads.
 *
 * A thread keeps a stack of recovery points (sigsetjmp buffers); a panic (rc.c auk__panic) on a
 * thread with one records its message here and jumps back to the innermost one instead of
 * ending the process. Nothing between the jump and the recovery point is cleaned up: Auk
 * objects the aborted code owned leak (bounded per panic), and `var` state it was changing
 * stays half-changed.
 *
 * This is the runtime's only use of setjmp/longjmp; keep it that way (docs/self-host-plan.md,
 * Phase 7). */
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

typedef struct CatchFrame {
    sigjmp_buf jb;
    struct CatchFrame *prev;
} CatchFrame;

static _Thread_local CatchFrame *top;
/* The panic being carried to a recovery point (malloc'd; taken by auk__catch_take). */
static _Thread_local char *caught_msg;
static _Thread_local char *caught_loc;

int auk__catch_run(AukThunk f, void *env, void *out) {
    CatchFrame fr;
    fr.prev = top;
    /* savemask 0: no signal-mask syscall per catch */
    if (sigsetjmp(fr.jb, 0) == 0) {
        top = &fr;
        f(env, out);
        top = fr.prev;
        return 0;
    }
    top = fr.prev;
    return 1;
}

int auk__catch_active(void) {
    return top != NULL;
}

static char *copy_bytes(const char *p, size_t n) {
    char *s = auk__xmalloc(n + 1);
    memcpy(s, p, n);
    s[n] = 0;
    return s;
}

_Noreturn void auk__catch_throw(const char *loc, const char *msg, size_t n) {
    free(caught_msg);
    free(caught_loc);
    caught_msg = copy_bytes(msg, n);
    caught_loc = copy_bytes(loc, strlen(loc));
    siglongjmp(top->jb, 1);
}

void auk__catch_take(char **msg, char **loc) {
    *msg = caught_msg;
    *loc = caught_loc;
    caught_msg = NULL;
    caught_loc = NULL;
}

/* Run f(env, out) under a recovery point: NULL if it finished, the panic (malloc'd; free it
 * with auk__panic_free) if one jumped back. The tracer's and the debugger's per-thread state
 * is put back as it was here. */
AukPanic *auk__catch_call(AukThunk f, void *env, void *out) {
    int64_t tdepth;
    int tmute;
    void *dtop;
    int64_t ddepth;
    auk__trace_save(&tdepth, &tmute);
    auk__dbg_save(&dtop, &ddepth);
    if (auk__catch_run(f, env, out) == 0) {
        return NULL;
    }
    auk__trace_restore(tdepth, tmute);
    auk__dbg_restore(dtop, ddepth);
    AukPanic *p = auk__xmalloc(sizeof(AukPanic));
    auk__catch_take(&p->msg, &p->loc);
    if (p->msg == NULL) {
        p->msg = copy_bytes("panic", 5);
        p->loc = copy_bytes("<unknown>", 9);
    }
    return p;
}

void auk__panic_free(AukPanic *p) {
    free(p->msg);
    free(p->loc);
    free(p);
}

/* The Err a recovered panic becomes: "panic: <msg> at <loc>". */
AukErr *auk__panic_err(const AukPanic *p) {
    AukStrBuf b = {0};
    auk__sb_put_cstr(&b, "panic: ");
    auk__sb_put_cstr(&b, p->msg);
    auk__sb_put_cstr(&b, " at ");
    auk__sb_put_cstr(&b, p->loc);
    return auk__err_sb(&b);
}

/* `catch e`: run the thunk (it writes e's value to out); NULL when it finished, else the panic
 * as a new (owned) Err and out untouched. */
AUK_API AukErr *auk_catch(AukThunk f, void *env, void *out) {
    AukPanic *p = auk__catch_call(f, env, out);
    if (p == NULL) {
        return NULL;
    }
    if (auk__task_cancelled()) {
        /* a cancelled task must end: pass the panic on to the next recovery point out (the
         * task's own, at the latest) */
        auk__catch_throw(p->loc, p->msg, strlen(p->msg));
    }
    AukErr *e = auk__panic_err(p);
    auk__panic_free(p);
    return e;
}
