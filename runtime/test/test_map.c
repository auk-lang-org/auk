/* {K: V}: insertion order, replacement, removal, COW. */
#include "harness.h"

static void put_si(DuckMap **m, const char *k, int64_t v) {
    DuckStr *ks = S(k);
    duck_map_set(m, &ks, &v);
    duck_release(ks);
}

static int64_t get_si(DuckMap *m, const char *k, bool *found) {
    DuckStr *ks = S(k);
    int64_t v = 0;
    *found = duck_map_get_opt(m, &ks, &v);
    duck_release(ks);
    return v;
}

TEST(map_insertion_order_and_replace) {
    DuckMap *m = duck_map_new(&duck_ops_str, &duck_ops_int);
    put_si(&m, "zebra", 1);
    put_si(&m, "apple", 2);
    put_si(&m, "mango", 3);
    CHECK_STR(duck_map_show(m), "{\"zebra\": 1, \"apple\": 2, \"mango\": 3}");
    put_si(&m, "apple", 20); /* replace keeps position */
    CHECK_STR(duck_map_show(m), "{\"zebra\": 1, \"apple\": 20, \"mango\": 3}");
    CHECK_INT(duck_map_len(m), 3);
    bool found;
    CHECK(get_si(m, "apple", &found) == 20 && found);
    get_si(m, "nope", &found);
    CHECK(!found);
    DuckStr *k = S("zebra");
    CHECK(duck_map_contains(m, &k));
    int64_t old = 0;
    CHECK(duck_map_remove(&m, &k, &old) && old == 1);
    CHECK(!duck_map_remove(&m, &k, NULL));
    CHECK(!duck_map_contains(m, &k));
    CHECK_STR(duck_map_show(m), "{\"apple\": 20, \"mango\": 3}");
    put_si(&m, "zebra", 9); /* re-inserted keys go to the end */
    CHECK_STR(duck_map_show(m), "{\"apple\": 20, \"mango\": 3, \"zebra\": 9}");
    DuckArr *keys = duck_map_keys(m), *vals = duck_map_values(m);
    CHECK_STR(duck_arr_show(keys), "[\"apple\", \"mango\", \"zebra\"]");
    CHECK_STR(duck_arr_show(vals), "[20, 3, 9]");
    int64_t it = 0, n = 0;
    void *kp, *vp;
    while (duck_map_next(m, &it, &kp, &vp)) n += *(int64_t *)vp;
    CHECK_INT(n, 32);
    CHECK_INT(*(int64_t *)duck_map_at(m, &k, "t"), 9);
    duck_release(k), duck_release(keys), duck_release(vals), duck_release(m);
}

TEST(map_many_entries) {
    DuckMap *m = duck_map_new(&duck_ops_int, &duck_ops_int);
    for (int64_t i = 0; i < 5000; i++) {
        int64_t v = i * i;
        duck_map_set(&m, &i, &v);
    }
    CHECK_INT(duck_map_len(m), 5000);
    for (int64_t i = 0; i < 5000; i += 2) CHECK(duck_map_remove(&m, &i, NULL));
    CHECK_INT(duck_map_len(m), 2500);
    for (int64_t i = 0; i < 5000; i++) {
        int64_t *v = duck_map_find(m, &i);
        if (i % 2) CHECK(v && *v == i * i);
        else CHECK(!v);
    }
    /* order of the survivors is still insertion order */
    int64_t it = 0, prev = -1;
    void *k;
    while (duck_map_next(m, &it, &k, NULL)) {
        CHECK(*(int64_t *)k > prev);
        prev = *(int64_t *)k;
    }
    /* churn: remove/insert the same keys many times */
    for (int round = 0; round < 50; round++) {
        for (int64_t i = 1; i < 200; i += 2) {
            CHECK(duck_map_remove(&m, &i, NULL));
            duck_map_set(&m, &i, &i);
        }
    }
    CHECK_INT(duck_map_len(m), 2500);
    int64_t first = 0;
    it = 0;
    duck_map_next(m, &it, &k, NULL);
    first = *(int64_t *)k;
    CHECK_INT(first, 201); /* 1..199 were moved to the end */
    duck_release(m);
}

TEST(map_copy_on_write) {
    DuckMap *a = duck_map_new(&duck_ops_str, &duck_ops_str);
    DuckStr *k = S("k"), *v1 = S("v1"), *v2 = S("v2");
    duck_map_set(&a, &k, &v1);
    DuckMap *b = duck_retain(a);
    duck_map_set(&b, &k, &v2);
    CHECK(a != b);
    CHECK(duck_str_eq(*(DuckStr **)duck_map_at(a, &k, "t"), v1));
    CHECK(duck_str_eq(*(DuckStr **)duck_map_at(b, &k, "t"), v2));
    DuckMap *c = duck_retain(a);
    CHECK(duck_map_remove(&c, &k, NULL));
    CHECK_INT(duck_map_len(a), 1);
    CHECK_INT(duck_map_len(c), 0);
    CHECK(!duck_map_eq(a, b));
    DuckMap *d = duck_map_copy(a);
    CHECK(duck_map_eq(a, d));
    /* value object refcounts: v1 held by a and d */
    CHECK_INT(duck_refcount(v1), 3);
    /* setting a value that lives inside the map itself */
    duck_map_set(&d, &k, duck_map_at(d, &k, "t"));
    CHECK_INT(duck_refcount(v1), 3);
    duck_release(a), duck_release(b), duck_release(c), duck_release(d);
    CHECK_INT(duck_refcount(v1), 1);
    duck_release(k), duck_release(v1), duck_release(v2);
}

TEST(map_eq_ignores_order) {
    DuckMap *a = duck_map_new(&duck_ops_str, &duck_ops_int), *b = duck_map_new(&duck_ops_str, &duck_ops_int);
    put_si(&a, "x", 1);
    put_si(&a, "y", 2);
    put_si(&b, "y", 2);
    put_si(&b, "x", 1);
    CHECK(duck_map_eq(a, b));
    put_si(&b, "x", 3);
    CHECK(!duck_map_eq(a, b));
    duck_release(a), duck_release(b);
}

static void missing_key(void *p) {
    DuckStr *k = S("ghost");
    duck_map_at(p, &k, "m.duck:2:3");
}

TEST(map_missing_key_panics) {
    DuckMap *m = duck_map_new(&duck_ops_str, &duck_ops_int);
    EXPECT_PANIC(missing_key, m, "key not found: \"ghost\"\n  at m.duck:2:3");
    duck_release(m);
}

TEST(map_nested_values) {
    /* {str: [int]} with COW on the inner list */
    DuckMap *m = duck_map_new(&duck_ops_str, &duck_ops_arr);
    DuckStr *k = S("xs");
    DuckArr *xs = duck_arr_new(&duck_ops_int, 0);
    duck_map_set(&m, &k, &xs);
    DuckMap *snap = duck_retain(m);
    duck_map_make_unique(&m);
    DuckArr **slot = duck_map_find(m, &k);
    DUCK_ARR_PUSH(int64_t, slot, 7);
    CHECK_STR(duck_map_show(m), "{\"xs\": [7]}");
    CHECK_STR(duck_map_show(snap), "{\"xs\": []}");
    duck_release(m), duck_release(snap), duck_release(k), duck_release(xs);
}
