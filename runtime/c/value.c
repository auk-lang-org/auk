/* Value: the core data-tree enum. */
#include "auk_rt.h"

AUK_API AukValue auk_value_null(void) {
    AukValue v = {0};
    v.tag = AUK_V_NULL;
    return v;
}

AUK_API AukValue auk_value_bool(bool b) {
    AukValue v = {0}; /* the whole union zeroed first */
    v.tag = AUK_V_BOOL;
    v.u.b = b;
    return v;
}

AUK_API AukValue auk_value_int(int64_t i) {
    AukValue v = {0};
    v.tag = AUK_V_INT;
    v.u.i = i;
    return v;
}

AUK_API AukValue auk_value_float(double f) {
    AukValue v = {0};
    v.tag = AUK_V_FLOAT;
    v.u.f = f;
    return v;
}

AUK_API AukValue auk_value_str(AukStr *s) {
    AukValue v = {0};
    v.tag = AUK_V_STR;
    v.u.s = s == NULL ? auk_str_lit("") : auk_retain(s);
    return v;
}

AUK_API AukValue auk_value_list(AukArr *xs) {
    AukValue v = {0};
    v.tag = AUK_V_LIST;
    v.u.list = xs == NULL ? auk_value_list_new() : auk_retain(xs);
    return v;
}

AUK_API AukValue auk_value_map(AukMap *m) {
    AukValue v = {0};
    v.tag = AUK_V_MAP;
    v.u.map = m == NULL ? auk_value_map_new() : auk_retain(m);
    return v;
}

AUK_API AukArr *auk_value_list_new(void) {
    return auk_arr_new(&auk_ops_value, 0);
}

AUK_API AukMap *auk_value_map_new(void) {
    return auk_map_new(&auk_ops_str, &auk_ops_value);
}

AUK_API void auk_value_map_put(AukMap **pm, const char *key, AukValue val) {
    AukStr *k = auk_str_lit(key);
    auk_map_set(pm, &k, &val);
    auk_release(k);
}

static void *value_ptr(AukValue v) {
    switch (v.tag) {
    case AUK_V_STR:
        return v.u.s;
    case AUK_V_LIST:
        return v.u.list;
    case AUK_V_MAP:
        return v.u.map;
    default:
        return NULL;
    }
}

AUK_API void auk_value_retain(AukValue v) {
    auk_retain(value_ptr(v));
}

AUK_API void auk_value_release(AukValue v) {
    auk_release(value_ptr(v));
}

AUK_API const char *auk_value_tag_name(uint32_t t) {
    switch (t) {
    case AUK_V_NULL:
        return "Null";
    case AUK_V_BOOL:
        return "Bool";
    case AUK_V_INT:
        return "Int";
    case AUK_V_FLOAT:
        return "Float";
    case AUK_V_STR:
        return "Str";
    case AUK_V_LIST:
        return "List";
    case AUK_V_MAP:
        return "Map";
    default:
        return "?";
    }
}

/* want is "expected <Tag>, got ". */
static _Noreturn void mismatch(const char *loc, const char *want, AukValue v) {
    auk__panic3(loc, want, auk_value_tag_name(v.tag), NULL);
}

AUK_API bool auk_value_as_bool(AukValue v, const char *loc) {
    if (v.tag != AUK_V_BOOL) {
        mismatch(loc, "expected Bool, got ", v);
    }
    return v.u.b;
}

AUK_API int64_t auk_value_as_int(AukValue v, const char *loc) {
    if (v.tag != AUK_V_INT) {
        mismatch(loc, "expected Int, got ", v);
    }
    return v.u.i;
}

AUK_API double auk_value_as_float(AukValue v, const char *loc) {
    if (v.tag == AUK_V_INT) {
        return (double)v.u.i;
    }
    if (v.tag != AUK_V_FLOAT) {
        mismatch(loc, "expected Float, got ", v);
    }
    return v.u.f;
}

AUK_API AukStr *auk_value_as_str(AukValue v, const char *loc) {
    if (v.tag != AUK_V_STR) {
        mismatch(loc, "expected Str, got ", v);
    }
    return v.u.s;
}

AUK_API AukArr *auk_value_as_list(AukValue v, const char *loc) {
    if (v.tag != AUK_V_LIST) {
        mismatch(loc, "expected List, got ", v);
    }
    return v.u.list;
}

AUK_API AukMap *auk_value_as_map(AukValue v, const char *loc) {
    if (v.tag != AUK_V_MAP) {
        mismatch(loc, "expected Map, got ", v);
    }
    return v.u.map;
}

AUK_API bool auk_value_eq(AukValue a, AukValue b) {
    if (a.tag != b.tag) {
        return false;
    }
    switch (a.tag) {
    case AUK_V_NULL:
        return true;
    case AUK_V_BOOL:
        return a.u.b == b.u.b;
    case AUK_V_INT:
        return a.u.i == b.u.i;
    case AUK_V_FLOAT:
        return a.u.f == b.u.f;
    case AUK_V_STR:
        return auk_str_eq(a.u.s, b.u.s);
    case AUK_V_LIST:
        return auk_arr_eq(a.u.list, b.u.list);
    case AUK_V_MAP:
        return auk_map_eq(a.u.map, b.u.map);
    default:
        return false;
    }
}

AUK_API AukStr *auk_value_show(AukValue v) {
    switch (v.tag) {
    case AUK_V_NULL:
        return auk_str_lit("Null");
    case AUK_V_BOOL:
        return auk_str_from_bool(v.u.b);
    case AUK_V_INT:
        return auk_str_from_int(v.u.i);
    case AUK_V_FLOAT:
        return auk_str_from_float(v.u.f);
    case AUK_V_STR:
        return auk_str_quote(v.u.s);
    case AUK_V_LIST:
        return auk_arr_show(v.u.list);
    case AUK_V_MAP:
        return auk_map_show(v.u.map);
    default:
        return auk_str_lit("?");
    }
}

static void v_retain(void *p) {
    auk_value_retain(*(AukValue *)p);
}

static void v_release(void *p) {
    auk_value_release(*(AukValue *)p);
}

static bool v_eq(const void *a, const void *b) {
    return auk_value_eq(*(const AukValue *)a, *(const AukValue *)b);
}

static uint64_t v_hash(const void *p) {
    const AukValue *v = p;
    switch (v->tag) {
    case AUK_V_STR:
        return auk_str_hash(v->u.s);
    case AUK_V_LIST:
        return auk_arr_hash(v->u.list);
    case AUK_V_FLOAT:
        return auk_ops_float.hash(&v->u.f);
    case AUK_V_INT:
        return auk_hash_int(v->u.i);
    case AUK_V_BOOL:
        return auk_hash_int((v->u.b ? 1 : 0) + 2);
    default:
        return (uint64_t)v->tag * 7919;
    }
}

static AukStr *v_show(const void *p) {
    return auk_value_show(*(const AukValue *)p);
}

AUK_API const AukElemOps auk_ops_value = {
    sizeof(AukValue), v_retain, v_release, v_eq, NULL, v_hash, v_show, auk__value_copy_elem,
};
