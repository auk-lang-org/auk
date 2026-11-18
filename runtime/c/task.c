/* Async tasks: one pthread per spawned task; await joins.
 *
 * A task is linked to whoever awaits it: a panic on the task's thread ends only the task
 * (catch.c), and `await` raises it again in the awaiter, where a `catch` can recover it. A task
 * that panicked and is dropped without being awaited ends the process, so no panic goes
 * unreported.
 *
 * Cancelling a task is cooperative: `t.cancel()` sets a flag that the task checks at loop
 * back-edges (generated code reads auk_cancel_pending first, so loops pay one load while no task
 * is cancelled) and in blocking calls (sleep, await, net I/O wait in short slices). The check
 * panics "cancelled", and once a task is cancelled no `catch` inside it can keep it alive.
 *
 * Tasks are linked to the tasks they start, as Erlang processes are: when a task ends with a
 * panic (a crash, or its own cancellation), every task it started that is still running is
 * cancelled, so a failed supervisor takes its whole subtree down. A normal end cancels nothing. */
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "auk_rt.h"

struct AukTask {
    AukHeader h;
    pthread_t th;
    pthread_mutex_t mu;
    AukThunk fn;
    void *args;
    void *result;
    size_t result_size;
    const AukElemOps *ops;
    bool joined;
    /* set when the task's code panicked */
    AukPanic *panic;
    /* an awaiter has seen the panic */
    bool observed;
    /* cancel() was called before the task finished */
    _Atomic bool cancel;
    /* the task's code has finished (its result or panic is set) */
    _Atomic bool done;
    /* the tasks this task started (retained), for the link: cancelled when it ends with a
     * panic */
    AukTask **kids;
    int64_t nkids;
    int64_t capkids;
    /* the task's own heap (heap.c): its arguments were copied into it, everything it allocates
     * goes there, and it is swept when the task crashes or is freed */
    AukHeap *heap;
    /* releases the arguments (what the thunk does after the call), for a task that crashed */
    void (*args_drop)(void *args);
    /* the code address of the task's one closure argument, when it has exactly one and nothing
     * else that could hold a closure (0 otherwise): `auk run --live` narrows what the task can
     * reach to it */
    uintptr_t hint;
};

/* How many tasks are cancelled but still running: generated loops check a task's flag only
 * while this is non-zero. */
AUK_API _Atomic int64_t auk_cancel_pending;

/* How many times `auk run --live` has swapped new code into this program (the driver bumps it
 * after each reload; 0 when not live). */
_Atomic int64_t auk__live_reloads;

/* The tasks whose code is running (for `auk run --live`: a reload that changes a type's layout
 * cancels the ones that use it). A task is on it from its start to its end, so a task on it
 * can't be freed while the list is locked. */
static pthread_mutex_t running_lock = PTHREAD_MUTEX_INITIALIZER;
static AukTask **running;
static int64_t nrunning;
static int64_t caprunning;

/* Guards the cancel/done transitions; done_cv is signalled whenever a task finishes. */
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t done_cv = PTHREAD_COND_INITIALIZER;
/* How long a blocking wait sleeps between cancel checks. */
enum { SLICE_MS = 50 };

/* The task this thread runs (NULL on the main thread). */
static _Thread_local AukTask *cur_task;

/* Cancel each running task that pick(ctx, entry, hint) selects (its thunk's address and its
 * closure hint); returns how many. */
int64_t auk__cancel_running(bool (*pick)(void *ctx, uintptr_t entry, uintptr_t hint), void *ctx) {
    pthread_mutex_lock(&running_lock);
    int64_t n = 0;
    for (int64_t i = 0; i < nrunning; i++) {
        AukTask *t = running[i];
        if (pick(ctx, (uintptr_t)t->fn, t->hint)) {
            auk_task_cancel(t);
            n++;
        }
    }
    pthread_mutex_unlock(&running_lock);
    return n;
}

/* Has the task running on this thread been cancelled? */
bool auk__task_cancelled(void) {
    return cur_task != NULL && atomic_load(&cur_task->cancel);
}

/* Is this thread a task's (so blocking calls must wake up to check for cancellation)? */
bool auk__on_task(void) {
    return cur_task != NULL;
}

/* Panic "cancelled" if this thread's task was cancelled. */
void auk__check_cancel(const char *loc) {
    if (auk__task_cancelled()) {
        auk__panic3(loc, "cancelled", NULL, NULL);
    }
}

/* The loop back-edge check (called only while auk_cancel_pending is non-zero). */
AUK_API void auk_cancel_check(const char *loc) {
    auk__check_cancel(loc);
}

/* Wait until fd is readable (or writable), waking every slice to check for cancellation. Off a
 * task thread it returns at once (the blocking call itself then waits). */
void auk__wait_fd(int fd, bool write) {
    if (!auk__on_task()) {
        return;
    }
    for (;;) {
        auk__check_cancel("a blocking call");
        struct pollfd p = {fd, write ? POLLOUT : POLLIN, 0};
        if (poll(&p, 1, SLICE_MS) != 0) {
            return;
        }
    }
}

/* Sleep ms, in slices on a task thread so a cancel ends it early. */
void auk__sleep_ms(int64_t ms) {
    int64_t left = ms;
    while (left > 0) {
        int64_t step = auk__on_task() && left > SLICE_MS ? SLICE_MS : left;
        struct timespec ts = {(time_t)(step / 1000), (long)((step % 1000) * 1000000)};
        while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
        }
        left -= step;
        auk__check_cancel("a blocking call");
    }
}

static void running_add(AukTask *t) {
    pthread_mutex_lock(&running_lock);
    if (nrunning == caprunning) {
        caprunning = caprunning == 0 ? 16 : caprunning * 2;
        running = auk__xrealloc(running, (size_t)caprunning * sizeof(AukTask *));
    }
    running[nrunning++] = t;
    pthread_mutex_unlock(&running_lock);
}

static void running_remove(AukTask *t) {
    pthread_mutex_lock(&running_lock);
    int64_t k = 0;
    for (int64_t i = 0; i < nrunning; i++) {
        if (running[i] != t) {
            running[k++] = running[i];
        }
    }
    nrunning = k;
    pthread_mutex_unlock(&running_lock);
}

static void *task_entry(void *p) {
    AukTask *t = p;
    cur_task = t;
    auk__heap_switch(t->heap);
    running_add(t);
    AukPanic *pan = auk__catch_call(t->fn, t->args, t->result);
    if (pan != NULL) {
        t->panic = pan;
        /* the arguments' references (handles among them), then everything else the aborted
         * code left in the heap (nothing outside the heap points into it) */
        if (t->args_drop != NULL) {
            t->args_drop(t->args);
        }
        auk__heap_switch(NULL);
        auk__heap_sweep(t->heap);
        t->heap = NULL;
    }
    auk__heap_switch(NULL);
    free(t->args);
    t->args = NULL;
    if (t->kids != NULL) {
        for (int64_t i = 0; i < t->nkids; i++) {
            if (t->panic != NULL) {
                auk_task_cancel(t->kids[i]);
            }
            auk_release(t->kids[i]);
        }
        free(t->kids);
        t->kids = NULL;
        t->nkids = 0;
    }
    running_remove(t);
    pthread_mutex_lock(&state_lock);
    atomic_store(&t->done, true);
    if (atomic_load(&t->cancel)) {
        atomic_fetch_sub(&auk_cancel_pending, 1);
    }
    pthread_mutex_unlock(&state_lock);
    pthread_cond_broadcast(&done_cv);
    cur_task = NULL;
    return NULL;
}

/* `t.done()`: has the task finished (its result or panic is in)? */
AUK_API bool auk_task_done(AukTask *t) {
    return t != NULL && atomic_load(&t->done);
}

AUK_API int64_t auk_live_reloads(void) {
    return atomic_load(&auk__live_reloads);
}

/* `t.cancel()`: see the top of the file. No effect on a finished task. */
AUK_API void auk_task_cancel(AukTask *t) {
    if (t == NULL) {
        return;
    }
    pthread_mutex_lock(&state_lock);
    if (!atomic_load(&t->done) && !atomic_exchange(&t->cancel, true)) {
        atomic_fetch_add(&auk_cancel_pending, 1);
    }
    pthread_mutex_unlock(&state_lock);
}

/* Block until one of ts[0..n) is done (the lowest index wins); cancellable. */
static int64_t wait_any(AukTask **ts, int64_t n) {
    pthread_mutex_lock(&state_lock);
    for (;;) {
        for (int64_t i = 0; i < n; i++) {
            if (atomic_load(&ts[i]->done)) {
                pthread_mutex_unlock(&state_lock);
                return i;
            }
        }
        if (auk__task_cancelled()) {
            pthread_mutex_unlock(&state_lock);
            auk__check_cancel("a blocking call");
            pthread_mutex_lock(&state_lock);
            continue;
        }
        struct timeval now;
        gettimeofday(&now, NULL);
        int64_t ns = (int64_t)now.tv_usec * 1000 + (int64_t)SLICE_MS * 1000000;
        struct timespec until = {now.tv_sec + (time_t)(ns / 1000000000), (long)(ns % 1000000000)};
        pthread_cond_timedwait(&done_cv, &state_lock, &until);
    }
}

static void task_join(AukTask *t) {
    pthread_mutex_lock(&t->mu);
    if (!t->joined) {
        pthread_join(t->th, NULL);
        t->joined = true;
    }
    pthread_mutex_unlock(&t->mu);
}

/* `await any ts`: wait for the first task of ts to finish and return its index. Its result goes
 * to out (as auk_task_await writes it), or, when it panicked, the panic goes to *err as an owned
 * Err (the panic counts as seen). */
AUK_API int64_t auk_task_await_any(AukTask **ts, int64_t n, void *out, AukErr **err, const char *loc) {
    if (n <= 0) {
        auk__panic3(loc, "`await any` of an empty list", NULL, NULL);
    }
    int64_t i = wait_any(ts, n);
    AukTask *t = ts[i];
    task_join(t);
    if (t->panic != NULL) {
        t->observed = true;
        *err = auk__panic_err(t->panic);
    } else {
        auk_task_await(t, out);
    }
    return i;
}

AUK_API AukTask *auk_task_spawn(AukThunk fn, const void *args, size_t args_size, size_t result_size,
                                const AukElemOps *result_ops, void *heap, void (*args_drop)(void *args),
                                const void *hint) {
    AukTask *t = auk__alloc(sizeof(AukTask), AUK_K_TASK);
    t->heap = heap;
    t->args_drop = args_drop;
    t->hint = (uintptr_t)hint;
    pthread_mutex_init(&t->mu, NULL);
    t->fn = fn;
    t->args = auk__xmalloc(args_size);
    if (args_size != 0) {
        memcpy(t->args, args, args_size);
    }
    t->result = auk__xcalloc(1, result_size != 0 ? result_size : 1);
    t->result_size = result_size;
    t->ops = result_ops;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, (size_t)8 << 20);
    /* the link to the task that starts it (pruning the ones already finished) */
    AukTask *parent = cur_task;
    if (parent != NULL) {
        /* the runtime's own references: not the task's (not on its heap's ledger) */
        AukHeap *old = auk__heap_switch(NULL);
        int64_t k = 0;
        for (int64_t i = 0; i < parent->nkids; i++) {
            AukTask *kid = parent->kids[i];
            if (atomic_load(&kid->done)) {
                auk_release(kid);
            } else {
                parent->kids[k++] = kid;
            }
        }
        parent->nkids = k;
        if (parent->nkids == parent->capkids) {
            parent->capkids = parent->capkids == 0 ? 4 : parent->capkids * 2;
            parent->kids = auk__xrealloc(parent->kids, (size_t)parent->capkids * sizeof(AukTask *));
        }
        parent->kids[parent->nkids++] = auk_retain(t);
        auk__heap_switch(old);
    }
    int rc = pthread_create(&t->th, &attr, task_entry, t);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        auk__panic3("runtime", "could not start a task thread: ", strerror(rc), NULL);
    }
    return t;
}

AUK_API void auk_task_await(AukTask *t, void *out) {
    if (auk__on_task()) {
        wait_any(&t, 1);
    }
    task_join(t);
    if (t->panic != NULL) {
        /* the link: the task's panic is raised again here, at its original location */
        t->observed = true;
        auk__panic(t->panic->loc, t->panic->msg, strlen(t->panic->msg));
    }
    if (out != NULL && t->result_size != 0) {
        /* a deep copy into the awaiter's heap: the result stays in the task's */
        if (t->ops == NULL) {
            memcpy(out, t->result, t->result_size);
        } else {
            auk__copy_elem(t->ops, t->result, out);
        }
    }
}

AUK_API void auk_task_join_all(AukTask **ts, int64_t n) {
    for (int64_t i = 0; i < n; i++) {
        task_join(ts[i]);
    }
}

AUK_API void auk_task_await_all(AukTask **ts, int64_t n, void *outs) {
    auk_task_join_all(ts, n);
    for (int64_t i = 0; i < n; i++) {
        AukTask *t = ts[i];
        void *out = outs == NULL ? NULL : (uint8_t *)outs + (size_t)i * t->result_size;
        auk_task_await(t, out);
    }
}

void auk__task_free(AukTask *t) {
    task_join(t);
    if (t->panic != NULL) {
        AukPanic *p = t->panic;
        t->panic = NULL;
        /* a cancelled task's "cancelled" panic was asked for: not a crash to report */
        if (!t->observed && !atomic_load(&t->cancel)) {
            /* nobody awaited it: report it as an uncaught panic would be, and end the process */
            fflush(stdout);
            fprintf(stderr, "panic: %s\n  at %s\n  (in a task that was never awaited)\n", p->msg, p->loc);
            fflush(stderr);
            _exit(101);
        }
        auk__panic_free(p);
        /* the result was never written: don't release it */
        free(t->result);
        pthread_mutex_destroy(&t->mu);
        auk__free_obj(t);
        return;
    }
    if (t->ops != NULL && t->ops->release != NULL) {
        /* as the task: the result's handle references are on its ledger */
        AukHeap *old = auk__heap_switch(t->heap);
        t->ops->release(t->result);
        auk__heap_switch(old);
    }
    /* what is left of the task's heap: objects a `catch` inside it gave up on */
    auk__heap_sweep(t->heap);
    t->heap = NULL;
    free(t->result);
    pthread_mutex_destroy(&t->mu);
    auk__free_obj(t);
}
