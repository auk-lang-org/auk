/* User-level FFI (docs/ffi-plan.md): the core `ffi` module (`ffi.Ptr`, raw memory) and the
 * helpers generated code calls to marshal values to and from C: C strings and C arrays of list
 * elements. An `ffi.Ptr` (and every `extern type` of user code) is a plain machine address: not
 * reference counted, never freed automatically. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

/* ---- ffi.Ptr ------------------------------------------------------------------------------ */

AUK_API void *auk_ffi_ptr(int64_t addr) {
    return (void *)(intptr_t)addr;
}

AUK_API int64_t auk_ffi_addr(const void *p) {
    return (int64_t)(intptr_t)p;
}

/* "0x1f2e3d" (`"{p}"`); NULL is "0x0". */
AUK_API AukStr *auk_ffi_ptr_show(const void *p) {
    char buf[32];
    snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)(uintptr_t)p);
    return auk_str_lit(buf);
}

AUK_API void *auk_ffi_alloc(int64_t n, const char *loc) {
    if (n < 0) {
        auk_panic_str(loc, "ffi.alloc: negative size");
    }
    void *p = calloc(1, n == 0 ? 1 : (size_t)n);
    if (p == NULL) {
        auk_panic_str(loc, "ffi.alloc: out of memory");
    }
    return p;
}

/* ffi.symbol: the address of C symbol `name` in this process (the executable, the runtime,
 * every loaded library), or NULL. `auk build` exports the runtime's symbols from executables,
 * so a compiler written in Auk finds them for the code it JIT-compiles. */
AUK_API void *auk_ffi_symbol(const AukStr *name) {
    return dlsym(RTLD_DEFAULT, auk_str_cstr(name));
}

AUK_API void auk_ffi_free(void *p) {
    free(p);
}

static void check_ptr(const void *p, const char *what, const char *loc) {
    if (p == NULL) {
        char m[96];
        snprintf(m, sizeof m, "ffi.%s through a null pointer", what);
        auk_panic_str(loc, m);
    }
}

AUK_API int64_t auk_ffi_read_u8(const uint8_t *p, int64_t off, const char *loc) {
    check_ptr(p, "read_u8", loc);
    return p[off];
}

AUK_API int64_t auk_ffi_read_i32(const uint8_t *p, int64_t off, const char *loc) {
    check_ptr(p, "read_i32", loc);
    int32_t v;
    memcpy(&v, p + off, sizeof v);
    return v;
}

AUK_API int64_t auk_ffi_read_i64(const uint8_t *p, int64_t off, const char *loc) {
    check_ptr(p, "read_i64", loc);
    int64_t v;
    memcpy(&v, p + off, sizeof v);
    return v;
}

AUK_API double auk_ffi_read_f64(const uint8_t *p, int64_t off, const char *loc) {
    check_ptr(p, "read_f64", loc);
    double v;
    memcpy(&v, p + off, sizeof v);
    return v;
}

AUK_API void *auk_ffi_read_ptr(const uint8_t *p, int64_t off, const char *loc) {
    check_ptr(p, "read_ptr", loc);
    void *v;
    memcpy(&v, p + off, sizeof v);
    return v;
}

AUK_API void auk_ffi_write_u8(uint8_t *p, int64_t off, int64_t v, const char *loc) {
    check_ptr(p, "write_u8", loc);
    p[off] = (uint8_t)v;
}

AUK_API void auk_ffi_write_i32(uint8_t *p, int64_t off, int64_t v, const char *loc) {
    check_ptr(p, "write_i32", loc);
    int32_t x = (int32_t)v;
    memcpy(p + off, &x, sizeof x);
}

AUK_API void auk_ffi_write_i64(uint8_t *p, int64_t off, int64_t v, const char *loc) {
    check_ptr(p, "write_i64", loc);
    memcpy(p + off, &v, sizeof v);
}

AUK_API void auk_ffi_write_f64(uint8_t *p, int64_t off, double v, const char *loc) {
    check_ptr(p, "write_f64", loc);
    memcpy(p + off, &v, sizeof v);
}

AUK_API void auk_ffi_write_ptr(uint8_t *p, int64_t off, void *v, const char *loc) {
    check_ptr(p, "write_ptr", loc);
    memcpy(p + off, &v, sizeof v);
}

/* ffi.cstr: the C string at p, copied (invalid UTF-8 becomes U+FFFD). */
AUK_API AukStr *auk_ffi_cstr(const char *p, const char *loc) {
    check_ptr(p, "cstr", loc);
    return auk_str_lit(p);
}

/* ffi.bytes: n bytes at p as a list of ints 0..255. */
AUK_API AukArr *auk_ffi_bytes(const uint8_t *p, int64_t n, const char *loc) {
    if (n < 0) {
        auk_panic_str(loc, "ffi.bytes: negative length");
    }
    AukArr *out = auk_arr_new(&auk_ops_int, n);
    if (n == 0) {
        return out;
    }
    check_ptr(p, "bytes", loc);
    int64_t *d = auk_arr_make_unique(&out);
    for (int64_t i = 0; i < n; i++) {
        d[i] = p[i];
    }
    out->len = n;
    return out;
}

/* ---- marshalling (generated code) --------------------------------------------------------- */

/* A string result of a C function: copied; NULL panics (`str`, not `str?`). */
AUK_API AukStr *auk_ffi_str(const char *p, const char *fn, const char *loc) {
    if (p == NULL) {
        char m[160];
        snprintf(m, sizeof m, "%s returned NULL where a `str` was expected (declare the result `str?`)", fn);
        auk_panic_str(loc, m);
    }
    return auk_str_lit(p);
}

/* A `str?` from C: NULL stays NULL (the `none` case), anything else is copied. */
AUK_API AukStr *auk_ffi_str_or_null(const char *p) {
    return p == NULL ? NULL : auk_str_lit(p);
}

static size_t elem_size(int32_t kind, size_t raw) {
    switch (kind) {
    case AUK_FFI_I8:
    case AUK_FFI_U8:
        return 1;
    case AUK_FFI_I16:
    case AUK_FFI_U16:
        return 2;
    case AUK_FFI_I32:
    case AUK_FFI_U32:
    case AUK_FFI_F32:
        return 4;
    default:
        return raw;
    }
}

/* A malloc'd C array of a list's elements (`[T]` passed as `T *`), converted to `kind`. Never
 * NULL, so C sees a valid pointer for an empty list; free it with auk_ffi_free. */
AUK_API void *auk_ffi_arr_in(const AukArr *a, int32_t kind) {
    int64_t n = a == NULL ? 0 : a->len;
    size_t raw = a == NULL ? 8 : a->ops->size;
    size_t sz = elem_size(kind, raw);
    uint8_t *buf = auk__xmalloc(n == 0 ? 1 : (size_t)n * sz);
    if (n == 0) {
        return buf;
    }
    const uint8_t *src = a->data;
    if (kind == AUK_FFI_RAW) {
        memcpy(buf, src, (size_t)n * sz);
        return buf;
    }
    for (int64_t i = 0; i < n; i++) {
        if (kind == AUK_FFI_F32) {
            double x;
            memcpy(&x, src + i * 8, 8);
            float f = (float)x;
            memcpy(buf + i * 4, &f, 4);
            continue;
        }
        int64_t x;
        memcpy(&x, src + i * 8, 8);
        switch (kind) {
        case AUK_FFI_I8:
        case AUK_FFI_U8: {
            uint8_t v = (uint8_t)x;
            buf[i] = v;
            break;
        }
        case AUK_FFI_I16:
        case AUK_FFI_U16: {
            uint16_t v = (uint16_t)x;
            memcpy(buf + i * 2, &v, 2);
            break;
        }
        default: {
            uint32_t v = (uint32_t)x;
            memcpy(buf + i * 4, &v, 4);
            break;
        }
        }
    }
    return buf;
}

/* After a call that may have written the C array `buf` (a `var [T]` argument): copy it back
 * into the list (made unique first) and free it. */
AUK_API void auk_ffi_arr_out(AukArr **pa, void *buf, int32_t kind) {
    int64_t n = *pa == NULL ? 0 : (*pa)->len;
    if (n == 0) {
        free(buf);
        return;
    }
    size_t raw = (*pa)->ops->size;
    uint8_t *d = auk_arr_make_unique(pa);
    const uint8_t *src = buf;
    if (kind == AUK_FFI_RAW) {
        memcpy(d, src, (size_t)n * raw);
        free(buf);
        return;
    }
    for (int64_t i = 0; i < n; i++) {
        int64_t v = 0;
        switch (kind) {
        case AUK_FFI_I8:
            v = (int8_t)src[i];
            break;
        case AUK_FFI_U8:
            v = src[i];
            break;
        case AUK_FFI_I16: {
            int16_t x;
            memcpy(&x, src + i * 2, 2);
            v = x;
            break;
        }
        case AUK_FFI_U16: {
            uint16_t x;
            memcpy(&x, src + i * 2, 2);
            v = x;
            break;
        }
        case AUK_FFI_I32: {
            int32_t x;
            memcpy(&x, src + i * 4, 4);
            v = x;
            break;
        }
        case AUK_FFI_U32: {
            uint32_t x;
            memcpy(&x, src + i * 4, 4);
            v = x;
            break;
        }
        case AUK_FFI_F32: {
            float f;
            memcpy(&f, src + i * 4, 4);
            double x = f;
            memcpy(d + i * 8, &x, 8);
            continue;
        }
        default:
            break;
        }
        memcpy(d + i * 8, &v, 8);
    }
    free(buf);
}

/* ffi.from_bytes: a malloc'd copy of the bytes (ints 0..255); the caller frees it. */
AUK_API void *auk_ffi_from_bytes(const AukArr *a) {
    return auk_ffi_arr_in(a, AUK_FFI_U8);
}
