/* `{K: V}`: insertion-ordered hash map (an index table over an entries array), copy-on-write.
 *
 * Entries keep insertion order: entry i's key is at entries + i * stride, its value voff bytes
 * later; hashes[i] is its full hash and dead[i] marks a removed entry (kept, for order, until a
 * compaction). The index is open addressing with linear probing over icap slots: 0 is empty,
 * TOMB a removed entry, anything else the hash's upper 32 bits over (entry + 1), so a probe
 * rejects most other keys without touching their entries. */
#include <stdlib.h>
#include <string.h>

#include "auk_rt.h"

static const uint64_t EMPTY = 0;
static const uint64_t TOMB = UINT64_MAX;
/* The most entries a map holds (the entry number must fit the slot's low 32 bits). */
static const int64_t MAX_ENTRIES = (int64_t)UINT32_MAX - 2;

static uint64_t slot_of(uint64_t h, int64_t e) {
    return (h & ~(uint64_t)0xffffffff) | (uint64_t)(e + 1);
}

/* The entry a live slot points to. */
static int64_t entry_of(uint64_t x) {
    return (int64_t)(uint32_t)x - 1;
}

static bool live(uint64_t x) {
    return x != EMPTY && x != TOMB;
}

AUK_API int64_t auk_map_len(const AukMap *m) {
    return m == NULL ? 0 : m->len;
}

static int64_t round8(size_t n) {
    return (int64_t)((n + 7) / 8 * 8);
}

AUK_API AukMap *auk_map_new(const AukElemOps *kops, const AukElemOps *vops) {
    if (kops == NULL || vops == NULL) {
        auk__panic_rt("auk_map_new: missing ops");
    }
    if (kops->hash == NULL || kops->eq == NULL) {
        auk__panic_rt("auk_map_new: key type needs hash and eq");
    }
    AukMap *m = auk__alloc(sizeof(AukMap), AUK_K_MAP);
    m->kops = kops;
    m->vops = vops;
    /* every Auk value's alignment is at most 8: the value starts at the key's size rounded up */
    m->voff = round8(kops->size);
    m->stride = m->voff + round8(vops->size);
    if (m->stride < 8) {
        m->stride = 8;
    }
    return m;
}

void auk__map_free(AukMap *m) {
    for (int64_t i = 0; i < m->n; i++) {
        if (m->dead[i]) {
            continue;
        }
        if (m->kops->release != NULL) {
            m->kops->release(auk__map_key(m, i));
        }
        if (m->vops->release != NULL) {
            m->vops->release(auk__map_val(m, i));
        }
    }
    free(m->entries);
    free(m->hashes);
    free(m->dead);
    free(m->index);
    auk__free_obj(m);
}

static void rebuild_index(AukMap *m, int64_t icap) {
    free(m->index);
    m->icap = icap;
    m->index = auk__xcalloc((size_t)icap, sizeof(uint64_t));
    uint64_t mask = (uint64_t)icap - 1;
    for (int64_t e = 0; e < m->n; e++) {
        if (m->dead[e]) {
            continue;
        }
        uint64_t h = m->hashes[e];
        uint64_t s = h & mask;
        while (m->index[s] != EMPTY) {
            s = (s + 1) & mask;
        }
        m->index[s] = slot_of(h, e);
    }
}

/* Drop dead entries (keeps order). The caller rebuilds the index. */
static void compact(AukMap *m) {
    int64_t k = 0;
    size_t stride = (size_t)m->stride;
    for (int64_t e = 0; e < m->n; e++) {
        if (m->dead[e]) {
            continue;
        }
        if (k != e) {
            memcpy(auk__map_key(m, k), auk__map_key(m, e), stride);
            m->hashes[k] = m->hashes[e];
            m->dead[k] = false;
        }
        k++;
    }
    m->n = k;
}

static void set_cap(AukMap *m, int64_t cap) {
    if (cap > MAX_ENTRIES) {
        auk__panic_rt("a map can't hold more than 4294967293 entries");
    }
    m->entries = auk__xrealloc(m->entries, (size_t)cap * (size_t)m->stride);
    m->hashes = auk__xrealloc(m->hashes, (size_t)cap * sizeof(uint64_t));
    m->dead = auk__xrealloc(m->dead, (size_t)cap * sizeof(bool));
    m->cap = cap;
}

static int64_t icap_for(int64_t cap) {
    int64_t ic = 8;
    while (ic < cap * 2) {
        ic *= 2;
    }
    return ic;
}

/* The index slot holding key k (hash h), or -1. */
static int64_t find_slot(const AukMap *m, const void *k, uint64_t h) {
    if (m == NULL || m->icap == 0) {
        return -1;
    }
    uint64_t mask = (uint64_t)m->icap - 1;
    AukEqFn eq = m->kops->eq;
    uint64_t fp = h >> 32;
    uint64_t s = h & mask;
    for (;;) {
        uint64_t x = m->index[s];
        if (x == EMPTY) {
            return -1;
        }
        if (x != TOMB && x >> 32 == fp && eq(auk__map_key(m, entry_of(x)), k)) {
            return (int64_t)s;
        }
        s = (s + 1) & mask;
    }
}

AUK_API void *auk_map_find(const AukMap *m, const void *k) {
    if (m == NULL) {
        return NULL;
    }
    int64_t s = find_slot(m, k, m->kops->hash(k));
    return s < 0 ? NULL : auk__map_val(m, entry_of(m->index[s]));
}

AUK_API void *auk_map_at(const AukMap *m, const void *k, const char *loc) {
    void *v = auk_map_find(m, k);
    if (v == NULL) {
        AukStr *ks = m != NULL && m->kops->show != NULL ? m->kops->show(k) : auk_str_lit("?");
        /* the key's text up to its first NUL byte */
        auk__panic3(loc, "key not found: ", auk_str_cstr(ks), NULL);
    }
    return v;
}

AUK_API bool auk_map_get_opt(const AukMap *m, const void *k, void *out) {
    void *v = auk_map_find(m, k);
    if (v == NULL) {
        return false;
    }
    memcpy(out, v, m->vops->size);
    if (m->vops->retain != NULL) {
        m->vops->retain(out);
    }
    return true;
}

AUK_API bool auk_map_contains(const AukMap *m, const void *k) {
    return auk_map_find(m, k) != NULL;
}

AUK_API AukMap *auk_map_copy(const AukMap *m) {
    AukMap *c = auk_map_new(m->kops, m->vops);
    if (m->len != 0) {
        set_cap(c, m->len);
        size_t stride = (size_t)m->stride;
        for (int64_t e = 0; e < m->n; e++) {
            if (m->dead[e]) {
                continue;
            }
            int64_t k = c->n++;
            memcpy(auk__map_key(c, k), auk__map_key(m, e), stride);
            if (m->kops->retain != NULL) {
                m->kops->retain(auk__map_key(c, k));
            }
            if (m->vops->retain != NULL) {
                m->vops->retain(auk__map_val(c, k));
            }
            c->hashes[k] = m->hashes[e];
            c->dead[k] = false;
        }
        c->len = c->n;
        rebuild_index(c, icap_for(c->cap));
    }
    return c;
}

AUK_API void *auk_map_make_unique(AukMap **pm) {
    AukMap *m = *pm;
    if (auk_refcount(m) != 1) {
        *pm = auk_map_copy(m);
        auk_release(m);
    }
    return *pm;
}

AUK_API void auk_map_set(AukMap **pm, const void *k_in, const void *v_in) {
    AukMap *m = *pm;
    /* hold copies of key and value (the value retained) before copy-on-write: they may live in
     * *pm */
    size_t ks = m->kops->size;
    size_t vs = m->vops->size;
    AukTmp kt;
    AukTmp vt;
    uint8_t *k = auk__tmp_get(&kt, ks);
    uint8_t *v = auk__tmp_get(&vt, vs);
    memcpy(k, k_in, ks);
    memcpy(v, v_in, vs);
    if (m->vops->retain != NULL) {
        m->vops->retain(v);
    }
    auk_map_make_unique(pm);
    m = *pm;
    uint64_t h = m->kops->hash(k);
    int64_t s = find_slot(m, k, h);
    if (s >= 0) {
        int64_t e = entry_of(m->index[s]);
        if (m->vops->release != NULL) {
            m->vops->release(auk__map_val(m, e));
        }
        memcpy(auk__map_val(m, e), v, vs);
    } else {
        if (m->kops->retain != NULL) {
            m->kops->retain(k);
        }
        if (m->n == m->cap) {
            if (m->n - m->len > m->len / 2 && m->n - m->len > 0) {
                compact(m);
            }
            if (m->n == m->cap) {
                set_cap(m, m->cap != 0 ? m->cap * 2 : 4);
            }
            rebuild_index(m, icap_for(m->cap));
        } else if (m->icap == 0) {
            rebuild_index(m, icap_for(m->cap));
        }
        int64_t e = m->n++;
        memcpy(auk__map_key(m, e), k, ks);
        memcpy(auk__map_val(m, e), v, vs);
        m->hashes[e] = h;
        m->dead[e] = false;
        m->len++;
        uint64_t mask = (uint64_t)m->icap - 1;
        uint64_t slot = h & mask;
        while (live(m->index[slot])) {
            slot = (slot + 1) & mask;
        }
        m->index[slot] = slot_of(h, e);
    }
    auk__tmp_done(&kt);
    auk__tmp_done(&vt);
}

AUK_API bool auk_map_remove(AukMap **pm, const void *k_in, void *out) {
    if (!auk_map_contains(*pm, k_in)) {
        return false;
    }
    size_t ks = (*pm)->kops->size;
    AukTmp kt;
    uint8_t *k = auk__tmp_get(&kt, ks);
    memcpy(k, k_in, ks);
    if ((*pm)->kops->retain != NULL) {
        (*pm)->kops->retain(k);
    }
    auk_map_make_unique(pm);
    AukMap *m = *pm;
    int64_t s = find_slot(m, k, m->kops->hash(k));
    int64_t e = entry_of(m->index[s]);
    m->index[s] = TOMB;
    m->dead[e] = true;
    m->len--;
    if (m->kops->release != NULL) {
        m->kops->release(auk__map_key(m, e));
    }
    if (out != NULL) {
        memcpy(out, auk__map_val(m, e), m->vops->size);
    } else if (m->vops->release != NULL) {
        m->vops->release(auk__map_val(m, e));
    }
    if (m->n - m->len > 16 && m->n - m->len > m->len) {
        compact(m);
        rebuild_index(m, icap_for(m->cap));
    }
    if (m->kops->release != NULL) {
        m->kops->release(k);
    }
    auk__tmp_done(&kt);
    return true;
}

AUK_API bool auk_map_next(const AukMap *m, int64_t *it, void **k, void **v) {
    if (m == NULL) {
        return false;
    }
    while (*it < m->n) {
        int64_t e = (*it)++;
        if (m->dead[e]) {
            continue;
        }
        if (k != NULL) {
            *k = auk__map_key(m, e);
        }
        if (v != NULL) {
            *v = auk__map_val(m, e);
        }
        return true;
    }
    return false;
}

AUK_API AukArr *auk_map_keys(const AukMap *m) {
    AukArr *a = auk_arr_new(m->kops, m->len);
    int64_t it = 0;
    void *k = NULL;
    while (auk_map_next(m, &it, &k, NULL)) {
        auk_arr_push(&a, k);
    }
    return a;
}

AUK_API AukArr *auk_map_values(const AukMap *m) {
    AukArr *a = auk_arr_new(m->vops, m->len);
    int64_t it = 0;
    void *v = NULL;
    while (auk_map_next(m, &it, NULL, &v)) {
        auk_arr_push(&a, v);
    }
    return a;
}

AUK_API bool auk_map_eq(const AukMap *a, const AukMap *b) {
    if (a == b) {
        return true;
    }
    if (auk_map_len(a) != auk_map_len(b)) {
        return false;
    }
    if (a == NULL || b == NULL) {
        return true; /* both empty */
    }
    int64_t it = 0;
    void *k = NULL;
    void *v = NULL;
    while (auk_map_next(a, &it, &k, &v)) {
        void *w = auk_map_find(b, k);
        if (w == NULL || a->vops->eq == NULL || !a->vops->eq(v, w)) {
            return false;
        }
    }
    return true;
}

AUK_API AukStr *auk_map_show(const AukMap *m) {
    AukStrBuf b = {0};
    auk_sb_char(&b, '{');
    int64_t it = 0;
    void *k = NULL;
    void *v = NULL;
    bool first = true;
    while (!auk__show_exhausted() && auk_map_next(m, &it, &k, &v)) {
        if (!first) {
            auk_sb_lit(&b, ", ");
        }
        first = false;
        if (m->kops->show == NULL || m->vops->show == NULL) {
            auk__panic_rt("show: key or value type has no show");
        }
        auk_sb_str_own(&b, m->kops->show(k));
        auk_sb_lit(&b, ": ");
        auk_sb_str_own(&b, m->vops->show(v));
    }
    auk_sb_char(&b, '}');
    return auk_sb_finish(&b);
}
