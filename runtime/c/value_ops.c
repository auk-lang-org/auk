/* auk_ops_value: the element ops of `Value`. Value itself is runtime/src/value.auk; this table
 * stays C until a raw global's initializer can hold function addresses (docs/lowlevel.md 7a:
 * "Not yet: addresses in initializers"). Its functions are value.auk's `export fn`s. */
#include "auk_rt.h"

void auk__value_elem_retain(void *p);
void auk__value_elem_release(void *p);
bool auk__value_elem_eq(const void *a, const void *b);
uint64_t auk__value_elem_hash(const void *p);
AukStr *auk__value_elem_show(const void *p);

AUK_API const AukElemOps auk_ops_value = {
    sizeof(AukValue), auk__value_elem_retain, auk__value_elem_release, auk__value_elem_eq, NULL,
    auk__value_elem_hash, auk__value_elem_show, auk__value_copy_elem,
};
