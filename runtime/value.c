/* Value: the core data-tree enum. */
#include "duck_internal.h"

DuckValue duck_value_null(void) { return (DuckValue){.tag = DUCK_V_NULL}; }
DuckValue duck_value_bool(bool b) { return (DuckValue){.tag = DUCK_V_BOOL, .u.b = b}; }
DuckValue duck_value_int(int64_t i) { return (DuckValue){.tag = DUCK_V_INT, .u.i = i}; }
DuckValue duck_value_float(double f) { return (DuckValue){.tag = DUCK_V_FLOAT, .u.f = f}; }
DuckValue duck_value_str(DuckStr *s) {
    return (DuckValue){.tag = DUCK_V_STR, .u.s = s ? duck_retain(s) : duck_str_lit("")};
}
DuckValue duck_value_list(DuckArr *xs) {
    return (DuckValue){.tag = DUCK_V_LIST, .u.list = xs ? duck_retain(xs) : duck_value_list_new()};
}
DuckValue duck_value_map(DuckMap *m) {
    return (DuckValue){.tag = DUCK_V_MAP, .u.map = m ? duck_retain(m) : duck_value_map_new()};
}

DuckArr *duck_value_list_new(void) { return duck_arr_new(&duck_ops_value, 0); }
DuckMap *duck_value_map_new(void) { return duck_map_new(&duck_ops_str, &duck_ops_value); }

void duck_value_map_put(DuckMap **pm, const char *key, DuckValue val) {
    DuckStr *k = duck_str_lit(key);
    duck_map_set(pm, &k, &val);
    duck_release(k);
}

static void *value_ptr(DuckValue v) {
    switch (v.tag) {
    case DUCK_V_STR: return v.u.s;
    case DUCK_V_LIST: return v.u.list;
    case DUCK_V_MAP: return v.u.map;
    default: return NULL;
    }
}

void duck_value_retain(DuckValue v) { duck_retain(value_ptr(v)); }
void duck_value_release(DuckValue v) { duck_release(value_ptr(v)); }

const char *duck_value_tag_name(DuckValueTag t) {
    switch (t) {
    case DUCK_V_NULL: return "Null";
    case DUCK_V_BOOL: return "Bool";
    case DUCK_V_INT: return "Int";
    case DUCK_V_FLOAT: return "Float";
    case DUCK_V_STR: return "Str";
    case DUCK_V_LIST: return "List";
    case DUCK_V_MAP: return "Map";
    }
    return "?";
}

static _Noreturn void mismatch(const char *loc, const char *want, DuckValue v) {
    duck_panic(loc, "expected %s, got %s", want, duck_value_tag_name(v.tag));
}

bool duck_value_as_bool(DuckValue v, const char *loc) {
    if (v.tag != DUCK_V_BOOL) mismatch(loc, "Bool", v);
    return v.u.b;
}
int64_t duck_value_as_int(DuckValue v, const char *loc) {
    if (v.tag != DUCK_V_INT) mismatch(loc, "Int", v);
    return v.u.i;
}
double duck_value_as_float(DuckValue v, const char *loc) {
    if (v.tag == DUCK_V_INT) return (double)v.u.i;
    if (v.tag != DUCK_V_FLOAT) mismatch(loc, "Float", v);
    return v.u.f;
}
DuckStr *duck_value_as_str(DuckValue v, const char *loc) {
    if (v.tag != DUCK_V_STR) mismatch(loc, "Str", v);
    return v.u.s;
}
DuckArr *duck_value_as_list(DuckValue v, const char *loc) {
    if (v.tag != DUCK_V_LIST) mismatch(loc, "List", v);
    return v.u.list;
}
DuckMap *duck_value_as_map(DuckValue v, const char *loc) {
    if (v.tag != DUCK_V_MAP) mismatch(loc, "Map", v);
    return v.u.map;
}

bool duck_value_eq(DuckValue a, DuckValue b) {
    if (a.tag != b.tag) return false;
    switch (a.tag) {
    case DUCK_V_NULL: return true;
    case DUCK_V_BOOL: return a.u.b == b.u.b;
    case DUCK_V_INT: return a.u.i == b.u.i;
    case DUCK_V_FLOAT: return a.u.f == b.u.f;
    case DUCK_V_STR: return duck_str_eq(a.u.s, b.u.s);
    case DUCK_V_LIST: return duck_arr_eq(a.u.list, b.u.list);
    case DUCK_V_MAP: return duck_map_eq(a.u.map, b.u.map);
    }
    return false;
}

DuckStr *duck_value_show(DuckValue v) {
    switch (v.tag) {
    case DUCK_V_NULL: return duck_str_lit("Null");
    case DUCK_V_BOOL: return duck_str_from_bool(v.u.b);
    case DUCK_V_INT: return duck_str_from_int(v.u.i);
    case DUCK_V_FLOAT: return duck_str_from_float(v.u.f);
    case DUCK_V_STR: return duck_str_quote(v.u.s);
    case DUCK_V_LIST: return duck_arr_show(v.u.list);
    case DUCK_V_MAP: return duck_map_show(v.u.map);
    }
    return duck_str_lit("?");
}

static void v_retain(void *p) { duck_value_retain(*(DuckValue *)p); }
static void v_release(void *p) { duck_value_release(*(DuckValue *)p); }
static bool v_eq(const void *a, const void *b) { return duck_value_eq(*(const DuckValue *)a, *(const DuckValue *)b); }
static uint64_t v_hash(const void *p) {
    const DuckValue *v = p;
    switch (v->tag) {
    case DUCK_V_STR: return duck_str_hash(v->u.s);
    case DUCK_V_LIST: return duck_arr_hash(v->u.list);
    case DUCK_V_FLOAT: return duck_ops_float.hash(&v->u.f);
    case DUCK_V_INT: return duck_hash_int(v->u.i);
    case DUCK_V_BOOL: return duck_hash_int(v->u.b + 2);
    default: return (uint64_t)v->tag * 7919u;
    }
}
static DuckStr *v_show(const void *p) { return duck_value_show(*(const DuckValue *)p); }
const DuckElemOps duck_ops_value = {sizeof(DuckValue), v_retain, v_release, v_eq, NULL, v_hash, v_show};
