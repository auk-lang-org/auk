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
