/* Deep copies, for values crossing a task boundary (heap.c): spawn arguments, `await` results
 * and channel messages. A copy is allocated in the current heap and shares nothing with the
 * original, except immortal objects (literals, imprints: never freed) and handles (tasks,
 * connections, listeners, channels: shared by reference count, never tracked). */
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

static bool immortal(const void *p) {
    return atomic_load_explicit(&((AukHeader *)p)->rc, memory_order_relaxed) < 0;
}

/* A closure env or box: size bytes with its drop and copy functions. */
AUK_API void *auk_obj_alloc(size_t size, AukDropFn drop, AukObjCopyFn copy) {
    if (size < sizeof(AukObj)) {
        size = sizeof(AukObj);
    }
    AukObj *o = auk__alloc(size, AUK_K_OBJ);
    o->drop = drop;
    o->copy = copy;
    return o;
}

AUK_API AukObj *auk_obj_copy(AukObj *o) {
    if (o == NULL || immortal(o)) {
        return o;
    }
    if (o->copy != NULL) {
        return o->copy(o);
    }
    return auk_retain(o);
}

AUK_API AukStr *auk_str_copy(AukStr *s) {
    if (s == NULL || immortal(s)) {
        return s;
    }
    return auk_str_from_bytes((const char *)s->data, s->len_bytes);
}

/* Copy one element of ops from src to dst (a byte copy plus a retain without a `copy`). */
void auk__copy_elem(const AukElemOps *ops, const void *src, void *dst) {
    if (ops->copy != NULL) {
        ops->copy(src, dst);
        return;
    }
    memcpy(dst, src, ops->size);
    if (ops->retain != NULL) {
        ops->retain(dst);
    }
}

AUK_API AukArr *auk_arr_copy_deep(AukArr *a) {
    if (a == NULL || immortal(a)) {
        return a;
    }
    const AukElemOps *ops = a->ops;
    int64_t n = a->len;
    AukArr *b = auk_arr_new(ops, n);
    for (int64_t i = 0; i < n; i++) {
        auk__copy_elem(ops, auk_arr_at(a, i, NULL), b->data + (size_t)i * ops->size);
    }
    b->len = n;
    return b;
}

AUK_API AukMap *auk_map_copy_deep(AukMap *m) {
    if (m == NULL || immortal(m)) {
        return m;
    }
    const AukElemOps *kops = m->kops;
    const AukElemOps *vops = m->vops;
    AukMap *out = auk_map_new(kops, vops);
    void *kb = auk__xcalloc(1, kops->size);
    void *vb = auk__xcalloc(1, vops->size);
    for (int64_t i = 0; i < m->n; i++) {
        if (m->dead[i]) {
            continue;
        }
        auk__copy_elem(kops, auk__map_key(m, i), kb);
        auk__copy_elem(vops, auk__map_val(m, i), vb);
        /* the map retains its own copies of borrowed elements */
        auk_map_set(&out, kb, vb);
        if (kops->release != NULL) {
            kops->release(kb);
        }
        if (vops->release != NULL) {
            vops->release(vb);
        }
    }
    free(kb);
    free(vb);
    return out;
}

AUK_API AukErr *auk_err_copy_deep(AukErr *e) {
    if (e == NULL || immortal(e)) {
        return e;
    }
    AukStr *msg = auk_str_copy(e->msg);
    AukErr *c = auk_err_new(msg);
    auk_release(msg);
    c->code = e->code;
    c->cause = auk_err_copy_deep(e->cause);
    if (e->payload.data != NULL) {
        c->payload.type_id = e->payload.type_id;
        c->payload.ops = e->payload.ops;
        c->payload.data = auk__xmalloc(e->payload.ops->size);
        auk__copy_elem(e->payload.ops, e->payload.data, c->payload.data);
    }
    return c;
}

AUK_API AukValue auk_value_copy(AukValue v) {
    AukValue out = v;
    switch (v.tag) {
    case AUK_V_STR:
        out.u.s = auk_str_copy(v.u.s);
        break;
    case AUK_V_LIST:
        out.u.list = auk_arr_copy_deep(v.u.list);
        break;
    case AUK_V_MAP:
        out.u.map = auk_map_copy_deep(v.u.map);
        break;
    default:
        break;
    }
    return out;
}

/* ---- `copy` entries of the built-in element ops ---- */

void auk__str_copy_elem(const void *src, void *dst) {
    *(AukStr **)dst = auk_str_copy(*(AukStr *const *)src);
}

void auk__arr_copy_elem(const void *src, void *dst) {
    *(AukArr **)dst = auk_arr_copy_deep(*(AukArr *const *)src);
}

void auk__map_copy_elem(const void *src, void *dst) {
    *(AukMap **)dst = auk_map_copy_deep(*(AukMap *const *)src);
}

void auk__err_copy_elem(const void *src, void *dst) {
    *(AukErr **)dst = auk_err_copy_deep(*(AukErr *const *)src);
}

void auk__obj_copy_elem(const void *src, void *dst) {
    *(AukObj **)dst = auk_obj_copy(*(AukObj *const *)src);
}

/* A handle (a task): shared, not copied. */
void auk__handle_copy_elem(const void *src, void *dst) {
    *(void **)dst = auk_retain(*(void *const *)src);
}

/* A closure {code, env}: the same code with a copy of the env. */
void auk__closure_copy_elem(const void *src, void *dst) {
    const AukClosure *s = src;
    AukClosure *d = dst;
    d->fn = s->fn;
    d->env = s->env == NULL ? NULL : auk_obj_copy(s->env);
}

void auk__value_copy_elem(const void *src, void *dst) {
    *(AukValue *)dst = auk_value_copy(*(const AukValue *)src);
}
