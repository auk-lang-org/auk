/* Recovery points for `catch` and task threads.
 *
 * setjmp lives in C because Rust can't express a function that returns twice. A thread keeps a
 * stack of recovery points; a panic (rc.rs `panic_msg`) on a thread with one jumps back to the
 * innermost. Nothing between the jump and the recovery point is cleaned up: Duck objects the
 * aborted code owned leak (bounded per panic). */
#include <setjmp.h>
#include <stddef.h>

typedef void (*duck_thunk)(void *env, void *out);

struct duck_catch_frame {
    sigjmp_buf jb;
    struct duck_catch_frame *prev;
};

static _Thread_local struct duck_catch_frame *top;

/* Run f(env, out). Returns 0 when it finished, 1 when a panic jumped back here. */
int duck__catch_run(duck_thunk f, void *env, void *out) {
    struct duck_catch_frame fr;
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

int duck__catch_active(void) { return top != NULL; }

/* Jump to the innermost recovery point; only call when duck__catch_active(). */
void duck__catch_throw(void) { siglongjmp(top->jb, 1); }
