An unbalanced binary search tree of integers. Four functions:

- `insert(t, v)` returns the tree with `v` inserted (smaller values go left, larger go right); inserting a value that is already present returns the tree unchanged.
- `from_list(xs)` inserts the values of `xs` in order into an empty tree.
- `to_list(t)` returns the values in increasing order (in-order traversal).
- `height(t)` is the number of nodes on the longest path from the root to a leaf; the empty tree has height 0.

Trees are immutable values: `insert` must not modify its input.
