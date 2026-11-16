/* Async tasks: one pthread per spawned task; await joins. */
#include "duck_internal.h"

#include <pthread.h>

struct DuckTask {
    DuckHeader h;
    pthread_t th;
    pthread_mutex_t mu;
    DuckThunk fn;
    void *args;
    void *result;
    size_t result_size;
    const DuckElemOps *ops;
    bool joined;
};

static void *task_entry(void *p) {
    DuckTask *t = p;
    t->fn(t->args, t->result);
    free(t->args);
    t->args = NULL;
    return NULL;
}

DuckTask *duck_task_spawn(DuckThunk fn, const void *args, size_t args_size, size_t result_size,
                          const DuckElemOps *result_ops) {
    DuckTask *t = duck__alloc(sizeof(DuckTask), DUCK_K_TASK);
    pthread_mutex_init(&t->mu, NULL);
    t->fn = fn;
    t->args = duck__xmalloc(args_size);
    if (args_size) memcpy(t->args, args, args_size);
    t->result = duck__xcalloc(1, result_size ? result_size : 1);
    t->result_size = result_size;
    t->ops = result_ops;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    int rc = pthread_create(&t->th, &attr, task_entry, t);
    pthread_attr_destroy(&attr);
    if (rc != 0) duck_panic("runtime", "could not start a task thread: %s", strerror(rc));
    return t;
}

static void task_join(DuckTask *t) {
    pthread_mutex_lock(&t->mu);
    if (!t->joined) {
        pthread_join(t->th, NULL);
        t->joined = true;
    }
    pthread_mutex_unlock(&t->mu);
}

void duck_task_await(DuckTask *t, void *out) {
    task_join(t);
    if (out && t->result_size) {
        memcpy(out, t->result, t->result_size);
        if (t->ops && t->ops->retain) t->ops->retain(out);
    }
}

void duck_task_join_all(DuckTask **ts, int64_t n) {
    for (int64_t i = 0; i < n; i++) task_join(ts[i]);
}

void duck_task_await_all(DuckTask **ts, int64_t n, void *outs) {
    duck_task_join_all(ts, n);
    for (int64_t i = 0; i < n; i++) {
        void *out = outs ? (char *)outs + (size_t)i * ts[i]->result_size : NULL;
        duck_task_await(ts[i], out);
    }
}

void duck__task_free(DuckTask *t) {
    task_join(t);
    if (t->ops && t->ops->release) t->ops->release(t->result);
    free(t->result);
    pthread_mutex_destroy(&t->mu);
    duck__free_obj(t);
}
