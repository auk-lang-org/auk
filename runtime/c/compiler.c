/* Small entry points used only by compiler-generated code: messages that the generated code
 * would otherwise format itself, hashing helpers, and the imprint evaluator's protocol (see
 * src/build.rs: compile-time evaluation of `imprint` constants). */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "auk_rt.h"

/* <prefix><Value tag name> as a new error (from_value's "expected X for `T`, got Y"). */
AUK_API AukErr *auk__err_with_tag(const char *prefix, int tag) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, prefix);
    auk__sb_put_cstr(&m, auk_value_tag_name((uint32_t)tag));
    return auk__err_sb(&m);
}

/* <a><s up to a NUL><b> as a new error. */
AUK_API AukErr *auk__err_concat(const char *a, const AukStr *s, const char *b) {
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, a);
    auk__sb_put_cstr(&m, auk_str_cstr(s));
    auk__sb_put_cstr(&m, b);
    return auk__err_sb(&m);
}

/* The hash of a float (as the float element ops hash it). */
AUK_API uint64_t auk_hash_float(double x) {
    return auk_ops_float.hash(&x);
}

/* The hash of a Value (as the Value element ops hash it). */
AUK_API uint64_t auk_value_hash(const AukValue *v) {
    return auk_ops_value.hash(v);
}

/* ---- the imprint evaluator's records ------------------------------------------------------
 * Records go to the file named by the helper's argv[1]: `B<c>\n` / `E<c>\n` when constant c
 * starts / finishes computing, `C<c>\n` (then exit 3) when it is needed while being computed,
 * and `V<c> <value>\n` for each imprint's value: `N`, `T`, `F`, `I<int>;`, `D<16 hex digits:
 * the f64 bits>;`, `S<n>:<n bytes>`, `L<n>;<n values>` or `M<n>;<n (S-key, value) pairs>`. */

static pthread_mutex_t imprint_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *imprint_out;

/* Open the records file named by argv[1]; false without one. */
AUK_API bool auk__imprint_open(int argc, const char *const *argv) {
    if (argc < 2) {
        return false;
    }
    FILE *f = fopen(argv[1], "wb");
    if (f == NULL) {
        return false;
    }
    pthread_mutex_lock(&imprint_lock);
    imprint_out = f;
    pthread_mutex_unlock(&imprint_lock);
    return true;
}

AUK_API void auk__imprint_close(void) {
    pthread_mutex_lock(&imprint_lock);
    if (imprint_out != NULL) {
        fclose(imprint_out);
    }
    imprint_out = NULL;
    pthread_mutex_unlock(&imprint_lock);
}

AUK_API void auk__imprint_mark(int tag, int64_t c) {
    pthread_mutex_lock(&imprint_lock);
    if (imprint_out != NULL) {
        fprintf(imprint_out, "%c%lld\n", (char)tag, (long long)c);
        fflush(imprint_out);
    }
    pthread_mutex_unlock(&imprint_lock);
    if ((char)tag == 'C') {
        _exit(3);
    }
}

static void dump_str(FILE *f, const AukStr *s) {
    int64_t n = auk_str_byte_len(s);
    fprintf(f, "S%lld:", (long long)n);
    fwrite(auk_str_cstr(s), 1, (size_t)n, f);
}

static void dump(FILE *f, const AukValue *v) {
    switch (v->tag) {
    case AUK_V_NULL:
        fputc('N', f);
        break;
    case AUK_V_BOOL:
        fputc(v->u.b ? 'T' : 'F', f);
        break;
    case AUK_V_INT:
        fprintf(f, "I%lld;", (long long)v->u.i);
        break;
    case AUK_V_FLOAT:
        fprintf(f, "D%016llx;", (unsigned long long)auk_fbits(v->u.f));
        break;
    case AUK_V_STR:
        dump_str(f, v->u.s);
        break;
    case AUK_V_LIST: {
        const AukArr *a = v->u.list;
        int64_t n = auk_arr_len(a);
        fprintf(f, "L%lld;", (long long)n);
        for (int64_t i = 0; i < n; i++) {
            dump(f, &((const AukValue *)a->data)[i]);
        }
        break;
    }
    case AUK_V_MAP: {
        const AukMap *m = v->u.map;
        fprintf(f, "M%lld;", (long long)auk_map_len(m));
        int64_t it = 0;
        void *kp = NULL;
        void *vp = NULL;
        while (auk_map_next(m, &it, &kp, &vp)) {
            dump_str(f, *(AukStr **)kp);
            dump(f, vp);
        }
        break;
    }
    default:
        break;
    }
}

AUK_API void auk__imprint_value(int64_t c, const AukValue *v) {
    pthread_mutex_lock(&imprint_lock);
    if (imprint_out != NULL) {
        fprintf(imprint_out, "V%lld ", (long long)c);
        dump(imprint_out, v);
        fputc('\n', imprint_out);
        fflush(imprint_out);
    }
    pthread_mutex_unlock(&imprint_lock);
}
