/* Err: message, code, cause chain and an optional typed payload. */
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

/* New error; msg is borrowed. */
AUK_API AukErr *auk_err_new(const AukStr *msg) {
    AukErr *e = auk__alloc(sizeof(AukErr), AUK_K_ERR);
    e->msg = msg == NULL ? auk_str_lit("") : auk_retain((void *)msg);
    return e;
}

/* The bytes go through a string builder, so they count against a trace's show budget and
 * invalid UTF-8 is repaired. */
AukErr *auk__err_bytes(const char *msg, size_t n) {
    AukStrBuf b = {0};
    auk_sb_bytes(&b, msg, (int64_t)n);
    AukStr *s = auk_sb_finish(&b);
    AukErr *e = auk_err_new(s);
    auk_release(s);
    return e;
}

/* A new error with a NUL-terminated message. */
AUK_API AukErr *auk_err_new_cstr(const char *msg) {
    if (msg == NULL) {
        return auk__err_bytes("", 0);
    }
    return auk__err_bytes(msg, strlen(msg));
}

AUK_API AukErr *auk_err_wrap(const AukStr *msg, AukErr *cause) {
    AukErr *e = auk_err_new(msg);
    e->cause = auk_retain(cause);
    return e;
}

AUK_API AukErr *auk_err_typed(uint32_t type_id, const void *value, const AukElemOps *ops, const AukStr *msg) {
    AukStr *m;
    if (msg != NULL) {
        m = auk_retain((void *)msg);
    } else if (ops->show != NULL) {
        m = ops->show(value);
    } else {
        m = auk_str_lit("error");
    }
    AukErr *e = auk_err_new(m);
    auk_release(m);
    e->payload.type_id = type_id;
    e->payload.ops = ops;
    e->payload.data = auk__xmalloc(ops->size);
    memcpy(e->payload.data, value, ops->size);
    if (ops->retain != NULL) {
        ops->retain(e->payload.data);
    }
    return e;
}

AUK_API const void *auk_err_payload(const AukErr *e, uint32_t type_id) {
    if (e == NULL || e->payload.data == NULL || e->payload.type_id != type_id) {
        return NULL;
    }
    return e->payload.data;
}

AUK_API AukStr *auk_err_show(const AukErr *e) {
    AukStrBuf b = {0};
    for (const AukErr *c = e; c != NULL; c = c->cause) {
        if (c != e) {
            auk_sb_bytes(&b, ": ", 2);
        }
        auk_sb_str(&b, c->msg);
    }
    return auk_sb_finish(&b);
}

/* Iterative over the cause chain, so a long chain can't overflow the stack. */
void auk__err_free(AukErr *e) {
    while (e != NULL) {
        AukErr *next = e->cause;
        auk_release(e->msg);
        if (e->payload.data != NULL) {
            if (e->payload.ops->release != NULL) {
                e->payload.ops->release(e->payload.data);
            }
            free(e->payload.data);
        }
        auk__free_obj(e);
        if (next == NULL) {
            break;
        }
        if (atomic_fetch_sub_explicit(&next->h.rc, 1, memory_order_acq_rel) != 1) {
            break;
        }
        e = next;
    }
}

/* "<what> <subject>: <strerror>" (or "<what>: <strerror>") with code err. The subject is
 * taken as a C string: it ends at an embedded NUL. */
AukErr *auk__err_errno(const char *what, const AukStr *subject, int err) {
    const char *se = strerror(err);
    const char *subj = subject == NULL ? NULL : auk_str_cstr(subject);
    size_t nw = what == NULL ? 0 : strlen(what);
    size_t ns = subj == NULL ? 0 : strlen(subj) + 1;
    size_t ne = strlen(se);
    char *m = auk__xmalloc(nw + ns + 2 + ne);
    size_t k = 0;
    memcpy(m, what, nw);
    k += nw;
    if (subj != NULL) {
        m[k++] = ' ';
        memcpy(m + k, subj, ns - 1);
        k += ns - 1;
    }
    m[k++] = ':';
    m[k++] = ' ';
    memcpy(m + k, se, ne);
    k += ne;
    AukErr *e = auk__err_bytes(m, k);
    free(m);
    e->code = err;
    return e;
}
