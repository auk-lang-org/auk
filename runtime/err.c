/* Err: message, code, cause chain and an optional typed payload. */
#include "duck_internal.h"

#include <stdarg.h>

DuckErr *duck_err_new(const DuckStr *msg) {
    DuckErr *e = duck__alloc(sizeof(DuckErr), DUCK_K_ERR);
    e->msg = msg ? duck_retain((void *)msg) : duck_str_lit("");
    return e;
}

DuckErr *duck_err_fmt(const char *fmt, ...) {
    DuckStrBuf b = DUCK_SB_INIT;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    char *buf = duck__xmalloc((size_t)n + 1);
    va_start(ap, fmt);
    vsnprintf(buf, (size_t)n + 1, fmt, ap);
    va_end(ap);
    duck_sb_bytes(&b, buf, n);
    free(buf);
    DuckStr *s = duck_sb_finish(&b);
    DuckErr *e = duck_err_new(s);
    duck_release(s);
    return e;
}

DuckErr *duck_err_wrap(const DuckStr *msg, DuckErr *cause) {
    DuckErr *e = duck_err_new(msg);
    e->cause = duck_retain(cause);
    return e;
}

DuckErr *duck_err_typed(uint32_t type_id, const void *value, const DuckElemOps *ops, const DuckStr *msg) {
    DuckStr *m = msg ? duck_retain((void *)msg) : (ops->show ? ops->show(value) : duck_str_lit("error"));
    DuckErr *e = duck_err_new(m);
    duck_release(m);
    e->payload.type_id = type_id;
    e->payload.ops = ops;
    e->payload.data = duck__xmalloc(ops->size);
    memcpy(e->payload.data, value, ops->size);
    if (ops->retain) ops->retain(e->payload.data);
    return e;
}

const void *duck_err_payload(const DuckErr *e, uint32_t type_id) {
    if (!e || !e->payload.data || e->payload.type_id != type_id) return NULL;
    return e->payload.data;
}

DuckStr *duck_err_show(const DuckErr *e) {
    DuckStrBuf b = DUCK_SB_INIT;
    for (const DuckErr *c = e; c; c = c->cause) {
        if (c != e) duck_sb_lit(&b, ": ");
        duck_sb_str(&b, c->msg);
    }
    return duck_sb_finish(&b);
}

void duck__err_free(DuckErr *e) {
    /* iterative over the cause chain to avoid deep recursion */
    while (e) {
        DuckErr *next = e->cause;
        duck_release(e->msg);
        if (e->payload.data) {
            if (e->payload.ops->release) e->payload.ops->release(e->payload.data);
            free(e->payload.data);
        }
        duck__free_obj(e);
        if (!next) break;
        if (atomic_fetch_sub_explicit(&next->h.rc, 1, memory_order_acq_rel) != 1) break;
        e = next;
    }
}

DuckErr *duck__err_errno(const char *what, const DuckStr *subject, int err) {
    DuckErr *e = subject ? duck_err_fmt("%s %s: %s", what, duck_str_cstr(subject), strerror(err))
                         : duck_err_fmt("%s: %s", what, strerror(err));
    e->code = err;
    return e;
}
