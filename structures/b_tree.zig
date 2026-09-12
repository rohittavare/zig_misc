const std = @import("std");
const Allocator = std.mem.Allocator;

const BTreeInternalError = error{
    OutOfCapacity,
    IllegalSplit,
    IllegalInsert,
    InvalidIndex,
};

// adding a new element:
// [written, untested]
// 1. traverse to the appropriate leaf node
// 2. insert element
//    as needed:
//    split node into two leaf nodes & mid. go to step 2 with parent node
//    * if at root node, create new node & set as root

// removing an element:
// 1. traverse the tree & find the element
// 2. remove element
//    if internal node:
//    - try to merge both branches
//    - promote element from largest branch
//    if node shrinks past min size:
//    - if root node - do nothing
//    - else
//      - try to combime w/ peer & parent
//      - steal parent

// requirements:
// - easy way to traverse to leaf nodes:
//   - finding the correct pointer
//   - differentiate internal & leaf nodes
// - simple insertion (without overflow)
// - splitting - turn 1 node into 2 nodes + parent (with the requied element added in)
// - merging
//   - take 2 sub-nodes & parent and produce single node; update parent accordingly (when one child is too small)
//   - merge two sub-nodes without parent (when removing the parent)
// - steal parent (when child node is small)
// - promote child (when removing parent)

// invariants:
// - a node is either a leaf or internal node (node never switches types)
// - non-root nodes will always have N/2 elements
// - element in internal node will always have pointers to the left & right
// - all nodes will contain elements
fn BTreeNode(comptime N: usize, comptime T: type, comptime O: ?(fn (T, T) std.math.Order)) type {
    return struct {
        buf: []T,
        len: usize = 0,
        next: ?[]*Self = null,

        const Self = @This();
        const Order = O orelse std.math.order;

        //////////////////////////////
        //   Allocators             //
        //////////////////////////////
        // set of allocators to initialize new nodes based on:
        // - leaf - nodes only containing values
        // - internal - nodes containing values & pointers to other nodes
        // - split nodes - creating new node w/ 1 value & pointers to left & right nodes

        fn initLeaf(allocator: Allocator) !Self {
            return .{
                .buf = try allocator.alloc(T, N),
            };
        }

        fn initInternal(allocator: Allocator) !Self {
            var n: Self = try .initLeaf(allocator);
            errdefer n.deinit(allocator);
            n.next = try allocator.alloc(*Self, N + 1);
            return n;
        }

        fn initFromSplitNode(allocator: Allocator, e: T, l: *Self, r: *Self) !Self {
            var n: Self = try .initInternal(allocator);
            n.buf[0] = e;
            if (n.next) |next| {
                next[0] = l;
                next[1] = r;
            }
            n.len = 1;
            return n;
        }

        fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.buf);
            if (self.next) |next| allocator.free(next);
        }

        fn deinitRecursive(self: Self, allocator: Allocator) void {
            if (self.next) |next| {
                for (0..self.len + 1) |i| {
                    next[i].deinitRecursive(allocator);
                    allocator.destroy(next[i]);
                }
            }
            self.deinit(allocator);
        }

        /// returns a node generated from consecutive values & surrounding pointers of another node
        /// differs from initialization functions by being a method
        /// useful for splitting an oversized node
        fn range(self: Self, allocator: Allocator, l: usize, r: usize) !Self {
            if (l >= r or r > self.len) return BTreeInternalError.InvalidIndex;
            var n: Self = try .initLeaf(allocator);
            errdefer n.deinit(allocator);
            @memcpy(n.buf[0..(r - l)], self.buf[l..r]);
            if (self.next) |next| {
                const n_next = try allocator.alloc(*Self, N + 1);
                @memcpy(n_next[0..(r - l + 1)], next[l..(r + 1)]);
                n.next = n_next;
            }
            n.len = r - l;
            return n;
        }

        /// returns the index at which a particular value is found (if contained by the node)
        /// or otherwise the index at which the value should be inserted into the node
        /// it is the caller's responsibility to determine if the value is actually located at returned index
        /// if duplicate values exist, no guarantees on which duplicate's index is returned
        /// assumes the node contents in sorted order
        fn find(self: Self, e: T) usize {
            var start: usize, var end: usize = .{ 0, N };
            while (true) {
                const mid = (end + start) / 2;
                if (start == end) return mid;
                switch (Order(self.buf[mid], e)) {
                    .eq => return mid,
                    .gt => end = mid - 1,
                    .lt => start = mid + 1,
                }
            }
            unreachable;
        }

        /// simulates inserting value `e` into this node and returns dynamically allocated nodes representing the
        /// left half, right half and also median value of splitting the resulting oversized node.
        /// in some cases, child pointers may also accompany the value `e` which will be appropriately set in child nodes
        ///
        /// this method is needed in the BTree insertion algorithm, where nodes must retain a fixed max size
        /// nodes exceeding this size must be split in half into a median value & two accompanying child nodes
        /// the ordering of the node values & pointers must reflect the insertion of the critical value which cause nodes to exceed capacity
        fn split(self: Self, allocator: Allocator, e: T, i: usize, l: ?*Self, r: ?*Self) !struct { *Self, T, *Self } {
            if (self.len != N) return BTreeInternalError.IllegalSplit;
            if (i > N) return BTreeInternalError.InvalidIndex;
            if (self.next == null and (l != null or r != null)) return BTreeInternalError.IllegalSplit;
            if (self.next != null and (l == null or r == null)) return BTreeInternalError.IllegalSplit;

            var left: *Self = try allocator.create(Self);
            errdefer allocator.destroy(left);
            var right: *Self = try allocator.create(Self);
            errdefer allocator.destroy(right);
            var center: T = undefined;

            if (i == N / 2) {
                left.* = try self.range(allocator, 0, N / 2);
                errdefer left.deinit(allocator);
                if (left.next) |next| next[N / 2] = l orelse unreachable;
                right.* = try self.range(allocator, N / 2, N);
                errdefer right.deinit(allocator);
                if (right.next) |next| next[0] = r orelse unreachable;
                center = e;
            } else if (i > N / 2) {
                left.* = try self.range(allocator, 0, N / 2);
                errdefer left.deinit(allocator);
                right.* = try self.range(allocator, 1 + N / 2, N);
                errdefer right.deinit(allocator);
                try right.insert(e, i - N / 2 - 1, l, r);
                center = self.buf[N / 2];
            } else {
                left.* = try self.range(allocator, 0, N / 2 - 1);
                errdefer left.deinit(allocator);
                try left.insert(e, i, l, r);
                right.* = try self.range(allocator, N / 2, N);
                center = self.buf[N / 2 - 1];
            }
            return .{ left, center, right };
        }

        /// insert a value (and accompanying child pointers) into this node, if sufficient capacity
        /// it is up to the caller to precompute the correct index `i` to retain sorted ordering of node contents
        /// this is so that callers may supply already known indices e.g. when replacing a child node
        /// otherwise, they can use the `find` method to identify the correct value
        /// if node is at max capacity, use the `split` method instead
        fn insert(self: *Self, e: T, i: usize, l: ?*Self, r: ?*Self) !void {
            if (self.len == N) return BTreeInternalError.OutOfCapacity;
            if (i > self.len) return BTreeInternalError.InvalidIndex;
            if (self.next == null and (l != null or r != null)) return BTreeInternalError.IllegalInsert;
            if (self.next != null and (l == null or r == null)) return BTreeInternalError.IllegalInsert;

            for (0..(self.len - i)) |idx| {
                self.buf[self.len - idx] = self.buf[self.len - idx - 1];
            }
            self.buf[i] = e;

            if (self.next) |next| {
                for (0..(self.len - i)) |idx| {
                    next[self.len + 1 - idx] = next[self.len - idx];
                }
                next[i] = l orelse unreachable;
                next[i + 1] = r orelse unreachable;
            }

            self.len += 1;
        }
    };
}

fn test_init_mem_leak(allocator: Allocator) !void {
    const Node = BTreeNode(4, u8, null);

    var a: Node = try .initLeaf(allocator);
    defer a.deinit(allocator);

    var b: Node = try .initInternal(allocator);
    defer b.deinit(allocator);

    var c: Node = try .initFromSplitNode(allocator, 'a', &a, &b);
    defer c.deinit(allocator);
}

test "b_tree_node_init_deinit" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(4, u8, null);

    var a: Node = try .initLeaf(allocator);
    defer a.deinit(allocator);
    try std.testing.expectEqual(null, a.next);
    try std.testing.expectEqual(0, a.len);

    var b: Node = try .initInternal(allocator);
    defer b.deinit(allocator);
    _ = b.next orelse unreachable;
    try std.testing.expectEqual(0, b.len);

    const c: Node = try .initFromSplitNode(allocator, 'a', &a, &b);
    defer c.deinit(allocator);
    if (c.next) |next| {
        try std.testing.expectEqual(&a, next[0]);
        try std.testing.expectEqual(&b, next[1]);
    } else {
        unreachable;
    }
    try std.testing.expectEqual('a', c.buf[0]);
    try std.testing.expectEqual(1, c.len);

    try std.testing.checkAllAllocationFailures(allocator, test_init_mem_leak, .{});
}

fn test_range_mem_leak(allocator: Allocator) !void {
    const Node = BTreeNode(4, u8, null);

    var a_contents = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_contents = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    var c_contents = [_]u8{' '};

    var a: Node = .{
        .buf = a_contents[0..],
        .len = a_contents.len,
    };

    var b: Node = .{
        .buf = b_contents[0..],
        .len = b_contents.len,
    };

    var c_next = [_]*Node{ &a, &b };
    const c: Node = .{
        .buf = c_contents[0..],
        .len = c_contents.len,
        .next = c_next[0..],
    };

    const d = try a.range(allocator, 1, 3);
    defer d.deinit(allocator);

    const e = try c.range(allocator, 0, 1);
    defer e.deinit(allocator);
}

test "b_tree_range" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(6, u8, null);

    var a_contents = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_contents = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    var c_contents = [_]u8{' '};

    var a: Node = .{
        .buf = a_contents[0..],
        .len = a_contents.len,
    };

    var b: Node = .{
        .buf = b_contents[0..],
        .len = b_contents.len,
    };

    var c_next = [_]*Node{ &a, &b };
    const c: Node = .{
        .buf = c_contents[0..],
        .len = c_contents.len,
        .next = c_next[0..],
    };

    const d = try a.range(allocator, 1, 3);
    defer d.deinit(allocator);
    try std.testing.expectEqualSlices(u8, a_contents[1..3], d.buf[0..d.len]);
    try std.testing.expectEqual(null, d.next);
    try std.testing.expectEqual(2, d.len);

    const e = try c.range(allocator, 0, 1);
    defer e.deinit(allocator);
    try std.testing.expectEqualSlices(u8, c_contents[0..], e.buf[0..e.len]);
    try std.testing.expectEqualSlices(*Node, c_next[0..], e.next.?[0 .. e.len + 1]);
    try std.testing.expectEqual(1, e.len);

    try std.testing.checkAllAllocationFailures(allocator, test_range_mem_leak, .{});
}

test "b_tree_find" {
    const Node = BTreeNode(6, u8, null);

    var node_contents = [_]u8{ 'a', 'b', 'g', 'l', 'y' };
    const node: Node = .{
        .buf = node_contents[0..],
        .len = node_contents.len,
    };

    try std.testing.expectEqual(0, node.find('a'));
    try std.testing.expectEqual(3, node.find('l'));
    try std.testing.expectEqual(2, node.find('c'));
}

test "b_tree_insert_leaf" {
    const Node = BTreeNode(6, u8, null);

    var node_contents = [_]u8{ 'a', 'g', 'l', 'y', 0, 0 };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 4,
    };

    try std.testing.expectError(BTreeInternalError.InvalidIndex, node.insert('b', 5, null, null));
    try std.testing.expectError(BTreeInternalError.IllegalInsert, node.insert('b', 1, &node, null));
    try std.testing.expectError(BTreeInternalError.IllegalInsert, node.insert('b', 1, null, &node));

    try std.testing.expectEqual(4, node.len);
    try node.insert('b', 1, null, null);
    try std.testing.expectEqual(5, node.len);
    try std.testing.expectEqualSlices(u8, "abgly", node.buf[0..node.len]);
    try node.insert('z', 5, null, null);
    try std.testing.expectEqual(6, node.len);
    try std.testing.expectEqualSlices(u8, "abglyz", node.buf[0..node.len]);

    try std.testing.expectError(BTreeInternalError.OutOfCapacity, node.insert('c', 2, null, null));
}

test "b_tree_insert_internal" {
    const Node = BTreeNode(6, u8, null);

    var node_contents = [_]u8{ 'b', 'g', 'l', 'y', 0, 0 };

    var nodes: [9]Node = undefined;
    var node_ptrs: [9]*Node = undefined;
    inline for (0..9) |i| {
        nodes[i] = .{
            .buf = node_contents[0..],
            .len = 0,
        };
        node_ptrs[i] = &nodes[i];
    }

    var node_next_contents = [_]*Node{
        node_ptrs[0],
        node_ptrs[1],
        node_ptrs[2],
        node_ptrs[3],
        node_ptrs[4],
        node_ptrs[0],
        node_ptrs[0],
    };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 4,
        .next = node_next_contents[0..],
    };

    try std.testing.expectError(BTreeInternalError.IllegalInsert, node.insert('a', 0, null, node_ptrs[6]));
    try std.testing.expectError(BTreeInternalError.IllegalInsert, node.insert('a', 0, node_ptrs[5], null));

    try std.testing.expectEqual(4, node.len);
    try node.insert('a', 0, node_ptrs[5], node_ptrs[6]);
    if (node.next) |next| {
        try std.testing.expectEqual(5, node.len);
        try std.testing.expectEqualSlices(*Node, &[_]*Node{
            node_ptrs[5],
            node_ptrs[6],
            node_ptrs[1],
            node_ptrs[2],
            node_ptrs[3],
            node_ptrs[4],
        }, next[0 .. node.len + 1]);
    } else {
        unreachable;
    }
    try node.insert('z', 5, node_ptrs[7], node_ptrs[8]);
    if (node.next) |next| {
        try std.testing.expectEqual(6, node.len);
        try std.testing.expectEqualSlices(*Node, &[_]*Node{
            node_ptrs[5],
            node_ptrs[6],
            node_ptrs[1],
            node_ptrs[2],
            node_ptrs[3],
            node_ptrs[7],
            node_ptrs[8],
        }, next[0 .. node.len + 1]);
    } else {
        unreachable;
    }
}

fn test_leaf_split_mem_leak(allocator: Allocator) !void {
    const Node = BTreeNode(6, u8, null);

    var node_contents = [_]u8{ 'a', 'g', 'k', 'm', 't', 'y' };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 6,
    };

    const l, _, const r = try node.split(allocator, 'b', 1, null, null);
    defer allocator.destroy(l);
    defer allocator.destroy(r);
    defer l.deinit(allocator);
    defer r.deinit(allocator);
}

test "b_tree_split_leaf" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(6, u8, null);

    var l: *Node, var e: u8, var r: *Node = .{ undefined, undefined, undefined };

    var node_contents = [_]u8{ 'a', 'g', 'k', 'm', 't', 'y' };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 4,
    };

    try std.testing.expectError(BTreeInternalError.IllegalSplit, node.split(allocator, 'n', 2, null, null));
    node.len = 6;
    try std.testing.expectError(BTreeInternalError.InvalidIndex, node.split(allocator, 'n', 7, null, null));
    try std.testing.expectError(BTreeInternalError.IllegalSplit, node.split(allocator, 'n', 4, &node, null));
    try std.testing.expectError(BTreeInternalError.IllegalSplit, node.split(allocator, 'n', 4, null, &node));

    {
        l, e, r = try node.split(allocator, 'b', 1, null, null);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('k', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "abg", l.buf[0..l.len]);
        try std.testing.expectEqual(null, l.next);
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "mty", r.buf[0..r.len]);
        try std.testing.expectEqual(null, r.next);
    }

    {
        l, e, r = try node.split(allocator, 'l', 3, null, null);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('l', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "agk", l.buf[0..l.len]);
        try std.testing.expectEqual(null, l.next);
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "mty", r.buf[0..r.len]);
        try std.testing.expectEqual(null, r.next);
    }

    {
        l, e, r = try node.split(allocator, 'n', 4, null, null);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('m', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "agk", l.buf[0..l.len]);
        try std.testing.expectEqual(null, l.next);
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "nty", r.buf[0..r.len]);
        try std.testing.expectEqual(null, r.next);
    }

    try std.testing.checkAllAllocationFailures(allocator, test_leaf_split_mem_leak, .{});
}

fn test_internal_split_mem_leak(allocator: Allocator) !void {
    const Node = BTreeNode(6, u8, null);
    var node_contents = [_]u8{ 'a', 'g', 'k', 'm', 't', 'y' };

    var nodes: [9]Node = undefined;
    var node_ptrs: [9]*Node = undefined;
    inline for (0..9) |i| {
        nodes[i] = .{
            .buf = node_contents[0..],
            .len = 0,
        };
        node_ptrs[i] = &nodes[i];
    }

    var node_next_contents = [_]*Node{
        node_ptrs[0],
        node_ptrs[1],
        node_ptrs[2],
        node_ptrs[3],
        node_ptrs[4],
        node_ptrs[5],
        node_ptrs[6],
    };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 6,
        .next = node_next_contents[0..],
    };

    const l, _, const r = try node.split(allocator, 'b', 1, node_ptrs[7], node_ptrs[8]);
    defer allocator.destroy(l);
    defer allocator.destroy(r);
    defer l.deinit(allocator);
    defer r.deinit(allocator);
}

test "b_tree_split_internal" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(6, u8, null);

    var node_contents = [_]u8{ 'a', 'g', 'k', 'm', 't', 'y' };

    var nodes: [9]Node = undefined;
    var node_ptrs: [9]*Node = undefined;
    inline for (0..9) |i| {
        nodes[i] = .{
            .buf = node_contents[0..],
            .len = 0,
        };
        node_ptrs[i] = &nodes[i];
    }

    var node_next_contents = [_]*Node{
        node_ptrs[0],
        node_ptrs[1],
        node_ptrs[2],
        node_ptrs[3],
        node_ptrs[4],
        node_ptrs[5],
        node_ptrs[6],
    };
    var node: Node = .{
        .buf = node_contents[0..],
        .len = 6,
        .next = node_next_contents[0..],
    };

    var l: *Node, var e: u8, var r: *Node = .{ undefined, undefined, undefined };

    try std.testing.expectError(BTreeInternalError.IllegalSplit, node.split(allocator, 'l', 3, node_ptrs[7], null));
    try std.testing.expectError(BTreeInternalError.IllegalSplit, node.split(allocator, 'l', 3, null, node_ptrs[8]));

    {
        l, e, r = try node.split(allocator, 'b', 1, node_ptrs[7], node_ptrs[8]);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('k', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "abg", l.buf[0..l.len]);
        if (l.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[0],
                node_ptrs[7],
                node_ptrs[8],
                node_ptrs[2],
            }, next[0 .. l.len + 1]);
        } else {
            unreachable;
        }
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "mty", r.buf[0..r.len]);
        if (r.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[3],
                node_ptrs[4],
                node_ptrs[5],
                node_ptrs[6],
            }, next[0 .. r.len + 1]);
        } else {
            unreachable;
        }
    }

    {
        l, e, r = try node.split(allocator, 'l', 3, node_ptrs[7], node_ptrs[8]);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('l', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "agk", l.buf[0..l.len]);
        if (l.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[0],
                node_ptrs[1],
                node_ptrs[2],
                node_ptrs[7],
            }, next[0 .. l.len + 1]);
        } else {
            unreachable;
        }
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "mty", r.buf[0..r.len]);
        if (r.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[8],
                node_ptrs[4],
                node_ptrs[5],
                node_ptrs[6],
            }, next[0 .. r.len + 1]);
        } else {
            unreachable;
        }
    }

    {
        l, e, r = try node.split(allocator, 'n', 4, node_ptrs[7], node_ptrs[8]);
        defer allocator.destroy(l);
        defer allocator.destroy(r);
        defer l.deinit(allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual('m', e);
        try std.testing.expectEqual(3, l.len);
        try std.testing.expectEqualSlices(u8, "agk", l.buf[0..l.len]);
        if (l.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[0],
                node_ptrs[1],
                node_ptrs[2],
                node_ptrs[3],
            }, next[0 .. l.len + 1]);
        } else {
            unreachable;
        }
        try std.testing.expectEqual(3, r.len);
        try std.testing.expectEqualSlices(u8, "nty", r.buf[0..r.len]);
        if (r.next) |next| {
            try std.testing.expectEqualSlices(*Node, &[_]*Node{
                node_ptrs[7],
                node_ptrs[8],
                node_ptrs[5],
                node_ptrs[6],
            }, next[0 .. r.len + 1]);
        } else {
            unreachable;
        }
    }

    try std.testing.checkAllAllocationFailures(allocator, test_internal_split_mem_leak, .{});
}

/// BTrees are a datastructure used to store set of data in order
/// related to B+Trees which databases use to manage indicies on disk
/// BTrees are a more generic form of a BST, storing up to N values
/// and N+1 pointers to child nodes
pub fn BTree(comptime N: usize, comptime T: type, comptime O: ?(fn (T, T) std.math.Order)) type {
    const TraversalPath = struct {
        n: []*BTreeNode(N, T, O),
        i: []usize,
    };

    return struct {
        root: *T_Node,
        depth: usize,

        const T_Node = BTreeNode(N, T, O);
        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .root = T_Node.fromLeaf(allocator, .init(allocator)),
                .depth = 1,
            };
        }

        /// Add a new element `e` into the BTree. Algorithm as follows:
        /// 1. traverse the BTree to find an index within a leaf node
        /// 2. attempt to insert the element in the leaf node. if the node overflows:
        /// 3. split node into two halves & a median
        /// 4. Attempt to insert the median into the parent node,
        ///    attaching the two halves as child nodes around the inserted median
        /// 5. if parent node overflows, repeat 3 & 4 with parent node
        ///    until a node inserts cleanly.
        ///    if root node overflows, create a new node to contain the median & child pointer
        /// Inserting from the leaf & breaking saturated nodes equally & distributing upwards
        /// ensures the tree stays balanced, ensuring each node remains at roughly the same capacity
        pub fn insert(self: *Self, allocator: Allocator, e: T) !void {
            const traversal: TraversalPath = .{
                .n = try allocator.alloc(*T_Node, self.depth),
                .i = try allocator.alloc(usize, self.depth),
            };
            defer allocator.free(traversal.n);
            defer allocator.free(traversal.i);

            // find the leaf node where the element should be inserted
            // keeping track of each node we've visited in case we need to back track
            var node = self.root;
            traversal.n[self.depth - 1] = node;
            traversal.i[self.depth - 1] = node.find(e);
            for (2..self.depth + 1) |i| {
                node = node.next.?[traversal.i[self.depth - i + 1]];
                traversal.n[self.depth - i] = node;
                traversal.i[self.depth - i] = i;
            }

            // starting from the bottom of our traversal chain attempt to insert our element
            // if our node overflows, split it and move up the traversal chain.
            // note: after our first insertion attempt, we are no longer just inserting our target element
            // we are actually building and attempting to insert a whole new subtree
            // replacing nodes in our traversal chain.
            const split_depth = insert: {
                var l: ?*T_Node, var elem, var r: ?*T_Node = .{ null, e, null };
                for (traversal.n, traversal.i, 0..) |n, i, idx| {
                    if (n.len == N) {
                        l, elem, r = try n.split(allocator, elem, i, l, r);
                    } else {
                        try n.insert(elem, i, l, r);
                        break :insert idx;
                    }
                }
                const tmp = try allocator.create(T_Node);
                errdefer allocator.destroy(tmp);
                tmp.* = try .initFromSplitNode(allocator, elem, l.?, r.?);
                self.root = tmp;
            } orelse self.depth;
            // free all the nodes below our split depth (replaced)
            for (traversal.n, 0..split_depth) |n, _| allocator.destroy(n);
        }

        pub fn delete(self: *Self, allocator: Allocator, e: T) void {
            _ = self;
            _ = allocator;
            _ = e;
        }
        pub fn contains(self: *const Self, e: T) bool {
            _ = self;
            _ = e;
            return false;
        }
        pub fn query_range(self: *const Self, l: T, r: T) []T {
            _ = self;
            _ = l;
            _ = r;
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            self.root.deinitRecursive(allocator);
            allocator.destroy(self.root);
        }
    };
}

fn _stringOrder(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}
fn StringBTreeNode(comptime N: usize) type {
    return BTreeNode(N, []const u8, _stringOrder);
}
pub fn StringBTree(comptime N: usize) type {
    return BTree(N, []const u8, _stringOrder);
}

/// allow ourselves to build a u8 BTree using compiletime specified structs
/// useful for writing readable test cases
fn literal_btree(comptime N: usize, comptime literal: anytype, allocator: Allocator) !StringBTree(N) {
    return .{ .root = try _recursive_build_tree(N, literal, allocator), .depth = comptime _validate_balanced_literal_tree(@TypeOf(literal)) };
}

/// validate the typing of our literal btree fields
/// inidividual tree elements should be literal strings
/// i.e. *const [_:0]u8
/// this utility checks if the type is const pionter to a u8 array
fn _is_literal_string(comptime T: type) bool {
    return eval_string: switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.attrs.@"const") switch (@typeInfo(p.child)) {
                .array => |a| break :eval_string a.child == u8,
                else => break :eval_string false,
            };
        },
        else => break :eval_string false,
    };
}

/// we will differentiate leaf literals based on in all tuple fields are literal strings
fn _all_fields_string(comptime s: std.builtin.Type.Struct) bool {
    inline for (s.field_types) |t| if (!_is_literal_string(t)) return false;
    return true;
}

/// BTrees are supposed to be balanced. While our insertion algorithm can guarantee this
/// if we are supplying pre-built trees in tests we need to validate up front
/// otherwise tests may not behave as we expect
///
/// in order for a tree to be balanced, it need to observe the same depth
/// across all its child nodes.
fn _validate_balanced_literal_tree(comptime t: type) usize {
    comptime {
        switch (@typeInfo(t)) {
            .@"struct" => |s| {
                // leaves are automatically depth 1
                if (_all_fields_string(s)) return 1;
                // track depth across each child node (even index fields)
                // we can recursively call this function at comptime to
                // compute the depth of children
                var depth = 0;
                for (s.field_types, 0..) |ty, i| {
                    if (i % 2 == 0) {
                        const d = _validate_balanced_literal_tree(ty);
                        if (depth == 0) {
                            depth = d;
                        } else if (depth != d) {
                            @compileError("unbalanced literal btree");
                        }
                    }
                }
                return depth + 1;
            },
            else => unreachable,
        }
    }
}

/// builds the outermost btree node and relies on recursion to generate child btree nodes
fn _recursive_build_tree(comptime N: usize, comptime literal: anytype, allocator: Allocator) !*StringBTreeNode(N) {
    switch (@typeInfo(@TypeOf(literal))) {
        .@"struct" => |s| {
            var node = try allocator.create(StringBTreeNode(N));
            errdefer allocator.destroy(node);
            // leaf nodes are represented as a tuple of string values
            if (comptime _all_fields_string(s)) {
                // definitely a leaf!
                if (s.field_names.len > N) @compileError("leaf node must contain between [1, N] elements");
                node.* = try .initLeaf(allocator);
                node.len = s.field_names.len;
                inline for (s.field_names, 0..) |name, i| {
                    node.buf[i] = @field(literal, name);
                }
                return node;
            } else {
                // assume it's an internal node
                // raise a compiler error
                // if we encounter something unexpected

                // internal nodes will contain fields for both child nodes & contained values
                // that's why we can expect up to 2N+1 fields
                if (s.field_names.len > 2 * N + 1 or s.field_names.len % 2 == 0 or s.field_names.len < 3) @compileError("internal nodes must contain between [1, N] values, and child nodes surrounding each value");
                node.* = try .initInternal(allocator);
                errdefer node.deinit(allocator);
                // fields alternate between child node objects & node contents
                // (emulating how child nodes contain elements between consecutive elements of a parent node)
                inline for (s.field_names, s.field_types, 0..) |n, t, i| {
                    switch (i % 2) {
                        0 => {
                            node.next.?[node.len] = _recursive_build_tree(N, @field(literal, n), allocator) catch |err| {
                                // if we failed to construct one of the child nodes, we have to make sure
                                // to free up any child *subtrees* we may have already built
                                for (node.next.?[0..node.len]) |child| {
                                    child.deinitRecursive(allocator);
                                    allocator.destroy(child);
                                }
                                return err;
                            };
                        },
                        1 => {
                            if (comptime !_is_literal_string(t)) @compileError("internal node contents must be literal string");
                            node.buf[node.len] = @field(literal, n);
                            node.len += 1;
                        },
                        else => unreachable,
                    }
                }
                return node;
            }
        },
        else => {},
    }
    @compileError("unknown literal btree");
}

/// utilities to assert equality of string BTrees
/// conditions for equality:
/// 1. trees have same depth value
/// 2. corresponding nodes have:
///    - same number of elements (and thereby same number of children)
///    - corresponding elements are equal (string comparison)
///    - corresponding children are equal (following above rules; if applicable)
fn expectEqualBTree(comptime N: usize, allocator: Allocator, comptime expected: anytype, actual: StringBTree(N)) !void {
    const expected_tree = try literal_btree(N, expected, allocator);
    defer expected_tree.deinit(allocator);
    try std.testing.expect(btree_cmp(N, expected_tree, actual));
}
fn btree_cmp(comptime N: usize, a: StringBTree(N), b: StringBTree(N)) bool {
    if (a.depth != b.depth) return false;
    return _recursive_btree_cmp(N, a.root, b.root);
}

fn _recursive_btree_cmp(comptime N: usize, a: *const StringBTreeNode(N), b: *const StringBTreeNode(N)) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (!std.mem.eql(u8, a.buf[i], b.buf[i])) return false;
    }
    if ((a.next == null and b.next != null) or (a.next != null and b.next == null)) return false;
    if (a.next) |a_next| {
        if (b.next) |b_next| {
            for (0..a.len + 1) |i| {
                if (!_recursive_btree_cmp(N, a_next[i], b_next[i])) return false;
            }
        } else return false;
    } else {
        if (b.next) |_| return false;
    }
    return true;
}

/// a depth 2 BTree of animal names
/// validate that a tree can gracefully handle memory failures during contruction & teardown
fn test_literal_btree_mem_leak(allocator: Allocator) !void {
    const tree = try literal_btree(4, .{
        .{ .{ "aardvark", "alligator", "bee" }, "boar", .{ "chickadee", "duck" }, "goat", .{ "goose", "hare" } },
        "horse",
        .{ .{ "iguana", "kangaroo" }, "llama", .{ "mouse", "muppet", "octopus" } },
        "panda",
        .{ .{ "parrot", "snail", "snake" }, "tarantula", .{ "termite", "whale" }, "yak", .{ "yink", "zoo" } },
    }, allocator);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(3, tree.depth);
}

test "test_literal_btree" {
    const allocator = std.testing.allocator;
    const tree_1 = try literal_btree(4, .{ "hello", "world" }, allocator);
    defer tree_1.deinit(allocator);
    try std.testing.expectEqual(1, tree_1.depth);

    const tree_2 = try literal_btree(4, .{ .{ "aardvark", "almanac" }, "bee", .{ "bus", "car" }, "doormat", .{ "elephant", "falcon", "gorilla" } }, allocator);
    defer tree_2.deinit(allocator);
    try std.testing.expectEqual(2, tree_2.depth);

    try expectEqualBTree(4, allocator, .{ .{ "aardvark", "almanac" }, "bee", .{ "bus", "car" }, "doormat", .{ "elephant", "falcon", "gorilla" } }, tree_2);

    try std.testing.checkAllAllocationFailures(allocator, test_literal_btree_mem_leak, .{});
}

// Insert Tests
// 1. insert into non-full root leaf node (leaf & non-leaf)
// 2. insert into full root node (leaf)
// 3. insert into non-root leaf node (non-full)
// 4. trigger leaf split
// 5. trigger leaf + interal split chain
// 6. trigger new root split chain
