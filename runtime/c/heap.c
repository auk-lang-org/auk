/* Per-task heaps: what makes a crashed task leave nothing behind.
 *
 * Every task thread allocates into a heap of its own. A tracked object has a hidden prefix just
 * before its header (Link: the heap's doubly linked list, and the heap itself), and its header's
 * flags say so; objects allocated with no current heap (the main thread, constants, handles)
 * have no prefix and are not tracked.
 *
 * Nothing crosses a task boundary by reference: spawn arguments are deep-copied into the new
 * task's heap, `await` deep-copies the result into the awaiter's, and channels copy messages.
 * Only handles (tasks, connections, listeners, channels, frames) are shared, and they are never
 * tracked. So when a task's heap goes (its task crashed, was cancelled or was freed), no object
 * outside the heap can point into it, and sweep frees everything still in it, whatever its
 * reference count says.
 *
 * Handles live outside every heap, so a heap also keeps a ledger of the references its task
 * took on handles (creating one counts, as do retains, minus releases). References held only by
 * the frames of a crashed task are on the ledger and nowhere else: the sweep gives them back,
 * closing the connections the task still had open. */
#include <pthread.h>
#include <stdlib.h>

#include "auk_rt.h"

/* The prefix of a tracked object (32 bytes, so the header stays 16-byte aligned). */
typedef struct Link {
    struct Link *prev;
    struct Link *next;
    AukHeap *heap;
    size_t pad;
} Link;

/* The handle ledger: handle address -> references held (open addressing, linear probing;
 * key 0 is an empty slot, a removed entry keeps its key with count 0 until the next grow). */
typedef struct Ledger {
    uintptr_t *keys;
    int64_t *counts;
    int64_t cap;
    int64_t used;
} Ledger;

struct AukHeap {
    pthread_mutex_t lock;
    Link head; /* the list's sentinel */
    pthread_mutex_t handles_lock;
    Ledger handles;
};

/* A reference count no release can bring to zero while a heap is swept. */
static const int64_t DYING = INT64_MAX / 4;

static _Thread_local AukHeap *cur_heap;

static uint64_t ledger_slot(uintptr_t key, int64_t cap) {
    return auk_hash_int((int64_t)key) & (uint64_t)(cap - 1);
}

static int64_t *ledger_entry(Ledger *l, uintptr_t key);

static void ledger_grow(Ledger *l) {
    uintptr_t *keys = l->keys;
    int64_t *counts = l->counts;
    int64_t cap = l->cap;
    l->cap = cap == 0 ? 16 : cap * 2;
    l->keys = auk__xcalloc((size_t)l->cap, sizeof(uintptr_t));
    l->counts = auk__xcalloc((size_t)l->cap, sizeof(int64_t));
    l->used = 0;
    for (int64_t i = 0; i < cap; i++) {
        if (keys[i] != 0 && counts[i] != 0) {
            *ledger_entry(l, keys[i]) = counts[i];
        }
    }
    free(keys);
    free(counts);
}

/* The count for key, adding the key (count 0) when it is missing. */
static int64_t *ledger_entry(Ledger *l, uintptr_t key) {
    if ((l->used + 1) * 4 > l->cap * 3) {
        ledger_grow(l);
    }
    uint64_t mask = (uint64_t)(l->cap - 1);
    uint64_t i = ledger_slot(key, l->cap);
    while (l->keys[i] != 0) {
        if (l->keys[i] == key) {
            return &l->counts[i];
        }
        i = (i + 1) & mask;
    }
    l->keys[i] = key;
    l->counts[i] = 0;
    l->used++;
    return &l->counts[i];
}

void auk__note_handle(const void *p, int64_t delta) {
    AukHeap *h = cur_heap;
    if (h == NULL) {
        return;
    }
    pthread_mutex_lock(&h->handles_lock);
    int64_t *n = ledger_entry(&h->handles, (uintptr_t)p);
    *n += delta;
    pthread_mutex_unlock(&h->handles_lock);
}

AukHeap *auk__heap_new(void) {
    AukHeap *h = auk__xcalloc(1, sizeof(AukHeap));
    pthread_mutex_init(&h->lock, NULL);
    pthread_mutex_init(&h->handles_lock, NULL);
    h->head.prev = &h->head;
    h->head.next = &h->head;
    return h;
}

AukHeap *auk__heap_current(void) {
    return cur_heap;
}

AukHeap *auk__heap_switch(AukHeap *h) {
    AukHeap *old = cur_heap;
    cur_heap = h;
    return old;
}

/* For generated code: switch heaps (a constant's initializer runs untracked, since its value
 * outlives the task that happened to compute it first). */
AUK_API void *auk_heap_switch(void *h) {
    return auk__heap_switch(h);
}

/* For generated code: a fresh heap for a task about to be spawned. */
AUK_API void *auk_heap_new(void) {
    return auk__heap_new();
}

/* Allocate size zeroed bytes for an object of kind in the current heap (untracked when there
 * is none, or for a handle kind). Returns the header's address. */
AukHeader *auk__heap_alloc(size_t size, uint32_t kind) {
    bool handle = auk__is_handle(kind);
    AukHeap *heap = handle ? NULL : cur_heap;
    if (heap == NULL) {
        AukHeader *h = auk__xcalloc(1, size);
        h->kind = kind;
        if (handle) {
            auk__note_handle(h, 1);
        }
        return h;
    }
    Link *l = auk__xcalloc(1, sizeof(Link) + size);
    AukHeader *h = (AukHeader *)((uint8_t *)l + sizeof(Link));
    h->kind = kind;
    h->flags = AUK_TRACKED;
    l->heap = heap;
    pthread_mutex_lock(&heap->lock);
    Link *s = &heap->head;
    l->prev = s;
    l->next = s->next;
    s->next->prev = l;
    s->next = l;
    pthread_mutex_unlock(&heap->lock);
    return h;
}

/* Free an object's memory (taking it off its heap's list). */
void auk__heap_free(AukHeader *h) {
    if ((h->flags & AUK_TRACKED) == 0) {
        free(h);
        return;
    }
    Link *l = (Link *)((uint8_t *)h - sizeof(Link));
    AukHeap *heap = l->heap;
    pthread_mutex_lock(&heap->lock);
    l->prev->next = l->next;
    l->next->prev = l->prev;
    pthread_mutex_unlock(&heap->lock);
    free(l);
}

/* Free every object still in heap, then the heap. No object outside it may point into it.
 * Each object is freed by its kind's ordinary free routine, so what it holds outside the heap
 * (handles) is released properly; objects inside the heap first get a reference count no
 * release can bring to zero, so each is freed exactly once, here. */
void auk__heap_sweep(AukHeap *heap) {
    if (heap == NULL) {
        return;
    }
    int64_t n = 0;
    int64_t cap = 0;
    AukHeader **objs = NULL;
    pthread_mutex_lock(&heap->lock);
    Link *s = &heap->head;
    Link *l = s->next;
    while (l != s) {
        AukHeader *h = (AukHeader *)((uint8_t *)l + sizeof(Link));
        Link *next = l->next;
        if (atomic_load(&h->rc) < 0) {
            /* immortal: it must stay; just take it off the list */
            l->prev->next = next;
            next->prev = l->prev;
            h->flags &= ~(uint32_t)AUK_TRACKED;
        } else {
            atomic_store(&h->rc, DYING);
            if (n == cap) {
                cap = cap == 0 ? 64 : cap * 2;
                objs = auk__xrealloc(objs, (size_t)cap * sizeof(AukHeader *));
            }
            objs[n++] = h;
        }
        l = next;
    }
    pthread_mutex_unlock(&heap->lock);
    /* free them as this heap's task would (their handle releases come off its ledger) */
    AukHeap *old = auk__heap_switch(heap);
    for (int64_t i = 0; i < n; i++) {
        auk__free_now(objs[i]);
    }
    free(objs);
    auk__heap_switch(NULL);
    pthread_mutex_lock(&heap->handles_lock);
    Ledger held = heap->handles;
    heap->handles = (Ledger){0};
    pthread_mutex_unlock(&heap->handles_lock);
    for (int64_t i = 0; i < held.cap; i++) {
        for (int64_t k = 0; k < held.counts[i]; k++) {
            auk_release((void *)held.keys[i]);
        }
    }
    free(held.keys);
    free(held.counts);
    auk__heap_switch(old == heap ? NULL : old);
    pthread_mutex_destroy(&heap->lock);
    pthread_mutex_destroy(&heap->handles_lock);
    free(heap);
}
