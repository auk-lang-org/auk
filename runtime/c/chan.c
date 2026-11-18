/* Channels: `Chan<T>` (core.auk) wraps an AukChan *, an unbounded FIFO shared by every copy of
 * the channel (a handle: never copied, never in a task's heap). send stores an untracked deep
 * copy of the message; recv deep-copies it again into the receiver's heap and frees the stored
 * one, so sender and receiver never share an object (heap.c). */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "auk_rt.h"

struct AukChan {
    AukHeader h;
    pthread_mutex_t lock;
    pthread_cond_t cv;
    const AukElemOps *ops;
    /* the queue: a ring of cap slots of size bytes, count of them from head */
    uint8_t *items;
    size_t size;
    int64_t cap;
    int64_t head;
    int64_t count;
    bool closed;
};

/* A new channel for elements described by proto's element ops (proto is an empty [T]). */
AUK_API AukChan *auk_chan_new(AukArr *proto) {
    AukChan *c = auk__alloc(sizeof(AukChan), AUK_K_CHAN);
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->cv, NULL);
    c->ops = proto->ops;
    c->size = c->ops->size > 0 ? c->ops->size : 1;
    return c;
}

static uint8_t *slot(AukChan *c, int64_t i) {
    return c->items + (size_t)((c->head + i) % c->cap) * c->size;
}

/* `c.send(x)`: queue a copy of *x. Panics on a closed channel. */
AUK_API void auk_chan_send(AukChan *c, const void *x, const char *loc) {
    AukTmp tmp;
    uint8_t *buf = auk__tmp_get(&tmp, c->size);
    AukHeap *old = auk__heap_switch(NULL);
    auk__copy_elem(c->ops, x, buf);
    auk__heap_switch(old);
    pthread_mutex_lock(&c->lock);
    if (c->closed) {
        pthread_mutex_unlock(&c->lock);
        if (c->ops->release != NULL) {
            c->ops->release(buf);
        }
        auk__tmp_done(&tmp);
        auk__panic3(loc, "send on a closed channel", NULL, NULL);
    }
    if (c->count == c->cap) {
        int64_t cap = c->cap == 0 ? 8 : c->cap * 2;
        uint8_t *items = auk__xmalloc((size_t)cap * c->size);
        for (int64_t i = 0; i < c->count; i++) {
            memcpy(items + (size_t)i * c->size, slot(c, i), c->size);
        }
        free(c->items);
        c->items = items;
        c->cap = cap;
        c->head = 0;
    }
    memcpy(slot(c, c->count), buf, c->size);
    c->count++;
    pthread_mutex_unlock(&c->lock);
    pthread_cond_signal(&c->cv);
    auk__tmp_done(&tmp);
}

/* Take the oldest message (lock held, count > 0) into buf. */
static void pop(AukChan *c, uint8_t *buf) {
    memcpy(buf, slot(c, 0), c->size);
    c->head = (c->head + 1) % c->cap;
    c->count--;
}

/* Copy a taken message to out (into this thread's heap) and free the stored copy. */
static void deliver(AukChan *c, uint8_t *buf, void *out) {
    auk__copy_elem(c->ops, buf, out);
    if (c->ops->release != NULL) {
        AukHeap *old = auk__heap_switch(NULL);
        c->ops->release(buf);
        auk__heap_switch(old);
    }
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Wait on c->cv (lock held) for at most ms milliseconds. */
static void wait_ms(AukChan *c, int64_t ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    int64_t ns = (int64_t)now.tv_usec * 1000 + ms * 1000000;
    struct timespec until = {now.tv_sec + (time_t)(ns / 1000000000), (long)(ns % 1000000000)};
    pthread_cond_timedwait(&c->cv, &c->lock, &until);
}

/* `c.recv_for(ms)` (ms < 0: `c.recv()`, no time limit): wait for a message and write a copy to
 * out; false once the channel is closed and empty, or when nothing came in time. Cancellable
 * on a task thread. */
static bool recv(AukChan *c, int64_t ms, void *out) {
    int64_t end = ms < 0 ? 0 : now_ms() + ms;
    AukTmp tmp;
    uint8_t *buf = auk__tmp_get(&tmp, c->size);
    pthread_mutex_lock(&c->lock);
    for (;;) {
        if (c->count > 0) {
            pop(c, buf);
            pthread_mutex_unlock(&c->lock);
            deliver(c, buf, out);
            auk__tmp_done(&tmp);
            return true;
        }
        int64_t left = ms < 0 ? 50 : end - now_ms();
        if (c->closed || (ms >= 0 && left <= 0)) {
            pthread_mutex_unlock(&c->lock);
            auk__tmp_done(&tmp);
            return false;
        }
        if (auk__on_task()) {
            pthread_mutex_unlock(&c->lock);
            auk__check_cancel("a channel receive");
            pthread_mutex_lock(&c->lock);
            wait_ms(c, left < 50 ? left : 50);
        } else if (ms < 0) {
            pthread_cond_wait(&c->cv, &c->lock);
        } else {
            wait_ms(c, left < 50 ? left : 50);
        }
    }
}

AUK_API bool auk_chan_recv(AukChan *c, void *out) {
    return recv(c, -1, out);
}

AUK_API bool auk_chan_recv_for(AukChan *c, int64_t ms, void *out) {
    return recv(c, ms < 0 ? 0 : ms, out);
}

/* `c.close()`: no more sends; receivers drain what is queued, then get none. */
AUK_API void auk_chan_close(AukChan *c) {
    pthread_mutex_lock(&c->lock);
    c->closed = true;
    pthread_mutex_unlock(&c->lock);
    pthread_cond_broadcast(&c->cv);
}

void auk__chan_free(AukChan *c) {
    for (int64_t i = 0; i < c->count; i++) {
        if (c->ops->release != NULL) {
            c->ops->release(slot(c, i));
        }
    }
    free(c->items);
    pthread_mutex_destroy(&c->lock);
    pthread_cond_destroy(&c->cv);
    auk__free_obj(c);
}
