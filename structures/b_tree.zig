const std = @import("std");
const Allocator = std.mem.Allocator;

const BTreeInternalError = error{
    OutOfCapacity,
    OutOfOrderInsertion,
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

fn BTreeNode(comptime N: usize, comptime T: type) type {
    return struct {
        buf: []T,
        len: usize = 0,
        next: ?[]*Self = null,

        const Self = @This();

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

        fn find(self: Self, e: T) usize {
            var start, var end = .{ 0, N };
            while (true) {
                const mid = (end + start) / 2;
                if (self.buf[mid] == e or start == end) {
                    return mid;
                } else if (mid > e) {
                    end = mid - 1;
                } else {
                    start = mid + 1;
                }
            }
            unreachable;
        }

        fn split(self: Self, allocator: Allocator, e: T, i: usize, l: ?*Self, r: ?*Self) !struct { *Self, T, *Self } {
            if (self.len != N) return BTreeInternalError.IllegalSplit;

            var left: Self = try allocator.create(Self);
            errdefer allocator.destroy(left);
            var right: Self = try allocator.create(Self);
            errdefer allocator.destroy(right);
            var center: T = undefined;

            if (i == N / 2) {
                left.* = try self.range(allocator, 0, N / 2);
                errdefer left.deinit(allocator);
                if (left.next) |next| next[N / 2] = l orelse return BTreeInternalError.IllegalSplit;
                right.* = try self.range(allocator, N / 2, N);
                errdefer right.deinit(allocator);
                if (right.next) |next| next[0] = r orelse return BTreeInternalError.IllegalSplit;
                center = e;
            } else if (i > N / 2) {
                left.* = try self.range(allocator, 0, N / 2);
                errdefer left.deinit(allocator);
                right.* = try self.range(allocator, 1 + N / 2, N);
                errdefer right.deinit(allocator);
                try right.insert(allocator, e, i - N / 2 - 1, l, r);
                center = self.buf[N / 2];
            } else {
                left.* = try self.range(allocator, 0, N / 2 - 1);
                errdefer left.deinit(allocator);
                try left.insert(allocator, e, i, l, r);
                right.* = try self.range(allocator, N / 2, N);
                center = self.buf[N / 2 - 1];
            }
            return .{ left, center, right };
        }

        fn insert(self: *Self, e: T, i: usize, l: ?*Self, r: ?*Self) !void {
            if (self.len == N) return BTreeInternalError.OutOfCapacity;
            if (i > 0 and self.buf[i - 1] > e) return BTreeInternalError.OutOfOrderInsertion;
            if (i < self.len and self.buf[i] < e) return BTreeInternalError.OutOfOrderInsertion;

            for (0..(self.len - i)) |idx| {
                self.buf[self.len - idx] = self.buf[self.len - idx - 1];
            }
            self.buf[i] = e;

            if (self.next) |next| {
                const left = l orelse return BTreeInternalError.IllegalInsert;
                const right = r orelse return BTreeInternalError.IllegalInsert;

                for (0..(self.len - i)) |idx| {
                    next[self.len + 1 - idx] = next[self.len - idx];
                }
                self.next[i] = left;
                self.next[i + 1] = right;
            } else if (l != null or r != null) {
                return BTreeInternalError.IllegalInsert;
            }

            self.len += 1;
        }
    };
}

fn test_init_mem_leak(allocator: Allocator) !void {
    const Node = BTreeNode(4, u8);

    var a: Node = try .initLeaf(allocator);
    defer a.deinit(allocator);

    var b: Node = try .initInternal(allocator);
    defer b.deinit(allocator);

    var c: Node = try .initFromSplitNode(allocator, 'a', &a, &b);
    defer c.deinit(allocator);
}

test "b_tree_node_init_deinit" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(4, u8);

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
    const Node = BTreeNode(4, u8);

    var a_contents = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_contents = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    var c_contents = [_]u8{' '};

    var a: Node = .{
        .buf = a_contents[0..],
        .len = 5,
    };

    var b: Node = .{
        .buf = b_contents[0..],
        .len = 5,
    };

    var c_next = [_]*Node{ &a, &b };
    const c: Node = .{
        .buf = c_contents[0..],
        .len = 1,
        .next = c_next[0..],
    };

    const d = try a.range(allocator, 1, 3);
    defer d.deinit(allocator);

    const e = try c.range(allocator, 0, 1);
    defer e.deinit(allocator);
}

test "b_tree_range" {
    const allocator = std.testing.allocator;

    const Node = BTreeNode(6, u8);

    var a_contents = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_contents = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    var c_contents = [_]u8{' '};

    var a: Node = .{
        .buf = a_contents[0..],
        .len = 5,
    };

    var b: Node = .{
        .buf = b_contents[0..],
        .len = 5,
    };

    var c_next = [_]*Node{ &a, &b };
    const c: Node = .{
        .buf = c_contents[0..],
        .len = 1,
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

pub fn BTree(comptime N: usize, comptime T: type) type {
    const BTreeTraversalLLNode = struct {
        n: ?*BTreeNode(N, T) = null,
        i: usize = 0,
        next: ?*Self = null,
        prev: ?*Self = null,

        const Self = @This();

        fn connect(self: ?*Self, allocator: Allocator, node: *const BTreeNode(N, T), idx: usize) !*Self {
            const new_node = try allocator.create(Self);
            new_node.* = .{
                .n = node,
                .i = idx,
                .next = self,
            };
            self.prev = new_node;
            return new_node;
        }

        fn free_chain(self: *const Self, allocator: Allocator) void {
            if (self.next) |next| next.free_chain(allocator);
            allocator.destroy(self);
        }

        fn free_nodes(self: *Self, allocator: Allocator) void {
            if (self.prev) |prev| prev.free_nodes(allocator);
            if (self.n) |n| allocator.destroy(n);
        }

        fn free_desc(self: *Self, allocator: Allocator) void {
            if (self.prev) |prev| prev.free_nodes(allocator);
        }
    };

    return struct {
        root: *T_Node,

        const T_Node = BTreeNode(N, T);
        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .root = T_Node.fromLeaf(allocator, .init(allocator)),
            };
        }

        pub fn insert(self: *Self, allocator: Allocator, e: T) !void {
            var traversal_chain: *BTreeTraversalLLNode = try allocator.create(BTreeTraversalLLNode);
            traversal_chain.* = .{};

            var node = self.root;
            while (true) {
                traversal_chain = try traversal_chain.connect(allocator, node, node.find(e));
                if (node.next) |next| {
                    node = next[traversal_chain.i];
                    continue;
                }
                break;
            }
            defer traversal_chain.free_chain(allocator);

            var l: ?*T_Node, var elem, var r: ?*T_Node = .{ null, e, null };
            while (traversal_chain.n) |n| {
                if (n.len == N) {
                    l, elem, r = try n.split(allocator, elem, traversal_chain.i, l, r);
                    traversal_chain = traversal_chain.next orelse unreachable;
                } else {
                    try n.insert(elem, traversal_chain.i, l, r);
                    break;
                }
            } else {
                const tmp = try allocator.create(T_Node);
                tmp.* = try .initFromSplitNode(allocator, elem, l.?, r.?);
                self.root = tmp;
            }
            traversal_chain.free_desc(allocator);
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
    };
}
