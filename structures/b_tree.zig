const std = @import("std");
const Allocator = std.mem.Allocator;

const BTreeInternalError = error{
    OutOfCapacity,
    OutOfOrderInsertion,
    SplittingNonFullNode,
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

fn BackPtr(comptime T: type) type {
    return struct {
        parent: *T,
        idx: usize,
    };
}

fn SplitNode(comptime N: usize, comptime T: type) type {
    return struct {
        left: *BTreeNode(N, T),
        center: T,
        right: *BTreeNode(N, T),
    };
}

fn BTreeLeaf(comptime N: usize, comptime T: type) type {
    return struct {
        len: usize,
        buf: []T,

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{
                .len = 0,
                .buf = try allocator.alloc(T, N),
            };
        }

        fn range(self: Self, allocator: Allocator, l: usize, r: usize) Self {
            const n: Self = .init(allocator);
            @memcpy(n.buf[0..(r - l)], self.buf[l..r]);
            n.len = r - l;
            return n;
        }

        fn insert(self: *Self, allocator: Allocator, e: T, i: usize) !void {
            if (self.len == N) return BTreeInternalError.OutOfCapacity;
            if (i > 0 and self.buf[i - 1] > e) return BTreeInternalError.OutOfOrderInsertion;
            if (i < self.len and self.buf[i] < e) return BTreeInternalError.OutOfOrderInsertion;
            const tmp = allocator.alloc(T, self.len - i);
            @memcpy(tmp, self.buf[i..self.len]);
            self.len += 1;
            @memcpy(self.buf[(i + 1)..self.len], tmp);
            self.buf[i] = e;
        }

        fn split(self: *Self, allocator: Allocator, e: T, i: usize) !SplitNode(N, T) {
            if (self.len != N) return BTreeInternalError.SplittingNonFullNode;
            var left: Self = undefined;
            var center: T = undefined;
            var right: Self = undefined;
            if (i == N / 2) {
                left = self.range(allocator, 0, N / 2);
                center = e;
                right = self.range(allocator, N / 2, N);
            } else if (i > N / 2) {
                left = self.range(allocator, 0, N / 2);
                center = self.buf[N / 2];
                right = self.range(allocator, 1 + N / 2, N);
                try right.insert(allocator, e, i - N / 2 - 1);
            } else {
                left = self.range(allocator, 0, N / 2 - 1);
                try left.insert(allocator, e, i);
                center = self.buf[N / 2 - 1];
                right = self.range(allocator, N / 2, N);
            }
            return .{
                .left = .fromLeaf(allocator, left),
                .center = center,
                .right = .fromLeaf(allocator, right),
            };
        }
    };
}

fn BTreeInternal(comptime N: usize, comptime T: type) type {
    return struct {
        len: usize,
        buf: []T,
        next: []*BTreeNode,

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{
                .len = 0,
                .buf = allocator.alloc(T, N),
                .next = allocator.alloc(T, N + 1),
            };
        }

        fn initFromSplitNode(allocator: Allocator, split_node: SplitNode(N, T)) Self {
            const node: Self = .init(allocator);
            node.buf[0] = split_node.center;
            node.next[0] = split_node.left;
            node.next[1] = split_node.right;
            node.len = 1;
            return node;
        }

        fn range(self: Self, allocator: Allocator, l: usize, r: usize) Self {
            const node: Self = .init(allocator);
            @memcpy(node.buf[0..(r - l)], self.buf[l..r]);
            @memcpy(node.next[0..(r - l + 1)], self.next[l..(r + 1)]);
            node.len = r - l;
            return node;
        }

        fn insert(self: *Self, allocator: Allocator, e: SplitNode(N, T), i: usize) !void {
            if (self.len == N) return BTreeInternalError.OutOfCapacity;
            if (i > 0 and self.buf[i - 1] > e.center) return BTreeInternalError.OutOfOrderInsertion;
            if (i < self.len and self.buf[i] < e.center) return BTreeInternalError.OutOfOrderInsertion;

            const tmp_buf = try allocator.alloc(T, self.len - i);
            @memcpy(tmp_buf, self.buf[i..self.len]);
            @memcpy(self.buf[(i + 1)..(self.len + 1)], tmp_buf);
            if (i < self.len) {
                const tmp_ptr = try allocator.alloc(*BTreeNode(N, T), self.len - i);
                @memcpy(tmp_ptr, self.next[(i + 1)..(self.len + 1)]);
                @memcpy(self.next[(i + 2)..(self.len + 2)], tmp_ptr);
            }

            self.len += 1;

            self.buf[i] = e.center;
            self.next[i] = e.left;
            self.next[i].back_ptr = .{
                .parent = self,
                .idx = i,
            };
            self.next[i + 1] = e.right;
            self.next[i + 1].back_ptr = .{
                .parent = self,
                .idx = i + 1,
            };
        }

        fn split(self: Self, allocator: Allocator, e: SplitNode(N, T), i: usize) !SplitNode(N, T) {
            if (self.len != N) return BTreeInternalError.SplittingNonFullNode;
            var left: Self = undefined;
            var center: T = undefined;
            var right: Self = undefined;
            if (i == N / 2) {
                left = self.range(allocator, 0, N / 2);
                left.next[N / 2] = e.left;
                center = e.center;
                right = self.range(allocator, N / 2, N);
                right.next[0] = e.right;
            } else if (i > N / 2) {
                left = self.range(allocator, 0, N / 2);
                center = self.buf[N / 2];
                right = self.range(allocator, 1 + N / 2, N);
                try right.insert(allocator, e, i - N / 2 - 1);
            } else {
                left = self.range(allocator, 0, N / 2 - 1);
                try left.insert(allocator, e, i);
                center = self.buf[N / 2 - 1];
                right = self.range(allocator, N / 2, N);
            }
            return .{
                .left = .fromInternal(allocator, left),
                .center = center,
                .right = .fromInternal(allocator, right),
            };
        }
    };
}

const FindResult = union(enum) {
    expected: usize,
    actual: usize,

    fn flatten(self: FindResult) usize {
        switch (self) {
            .expected => |v| return v,
            .actual => |v| return v,
        }
    }
};

fn find(comptime N: usize, comptime T: type, node: BTreeNode(N, T), e: T) FindResult {
    const buf = get_buf: switch (node.node) {
        .internal => |n| break :get_buf n.buf,
        .leaf => |n| break :get_buf n.buf,
    };
    var start, var end = .{ 0, N };
    while (true) {
        const mid = (end + start) / 2;
        if (buf[mid] == e) {
            return FindResult{
                .actual = mid,
            };
        } else if (start == end) {
            return FindResult{
                .expected = mid,
            };
        } else if (mid > e) {
            end = mid - 1;
        } else {
            start = mid + 1;
        }
    }
    unreachable;
}

fn CommonInputType(comptime N: usize, comptime T: type) type {
    return union {
        value: T,
        split_node: SplitNode(N, T),

        const Self = @This();

        fn fromValue(v: T) Self {
            return .{
                .value = v,
            };
        }
        fn fromSplitNode(s: SplitNode(N, T)) Self {
            return .{
                .split_node = s,
            };
        }
    };
}

fn BTreeNode(comptime N: usize, comptime T: type) type {
    return struct {
        node: NodeUnion,
        back_ptr: ?BackPtr(Self) = null,

        const NodeUnion = union(enum) {
            leaf: BTreeLeaf(N, T),
            internal: BTreeInternal(N, T),
        };
        const Self = @This();

        fn fromLeaf(allocator: Allocator, leaf: *BTreeLeaf(N, T)) *Self {
            const node = try allocator.create(Self);
            node.* = .{
                .node = .{
                    .leaf = leaf,
                },
            };
            return node;
        }

        fn fromInternal(allocator: Allocator, internal: *BTreeInternal(N, T)) *Self {
            const node = try allocator.create(Self);
            node.* = .{
                .node = .{
                    .internal = internal,
                },
            };
            return node;
        }

        fn insert(self: Self, allocator: Allocator, e: CommonInputType(N, T), i: usize) !void {
            switch (self.node) {
                .leaf => |n| try n.insert(allocator, e.value, i),
                .internal => |n| try n.insert(allocator, e.split_node, i),
            }
        }

        fn split(self: Self, allocator: Allocator, e: CommonInputType(N, T), i: usize) !SplitNode(N, T) {
            switch (self.node) {
                .leaf => |n| return try n.split(allocator, e.value, i),
                .internal => |n| return try n.split(allocator, e.split_node, i),
            }
        }
    };
}

const BTreeTraversalLLNode = struct {
    i: usize,
    next: ?*BTreeTraversalLLNode = null,

    fn free_chain(self: *const BTreeTraversalLLNode, allocator: Allocator) void {
        if (self.next) |next| next.free_chain(allocator);
        allocator.destroy(self);
    }
};

pub fn BTree(comptime N: usize, comptime T: type) type {
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
            var node = self.root;
            while (true) switch (node.node) {
                .internal => |n| node = n.next[find(N, T, n, e).flatten()],
                .leaf => {},
            };

            var traversal_chain: ?*BTreeTraversalLLNode = null;

            switch (find(N, T, node, e)) {
                .expected => |i| {
                    node.insert(allocator, .fromValue(e), i) catch |err| switch (err) {
                        BTreeInternalError.OutOfCapacity => {
                            var split_node = try node.split(allocator, .fromValue(e), i);
                            while (node.back_ptr) |ptr| {
                                ptr.parent.insert(allocator, split_node, ptr.idx) catch |err2| switch (err2) {
                                    BTreeInternalError.OutOfCapacity => {
                                        const traversal_node = try allocator.create(BTreeTraversalLLNode);
                                        traversal_node.* = .{
                                            .i = ptr.idx,
                                            .next = traversal_chain,
                                        };
                                        traversal_chain = traversal_node;
                                        split_node = node.split(allocator, split_node, ptr.idx);
                                        node = ptr.parent;
                                        continue;
                                    },
                                    else => return err2,
                                };
                                break;
                            } else {
                                self.root = .fromInternal(allocator, .initFromSplitNode(allocator, split_node));
                            }
                            while (traversal_chain) |traversal_node| {
                                const nn = node.node.internal.next[traversal_node.i];
                                allocator.destroy(node);
                                node = nn;
                                const ntraversal_node = traversal_node.next;
                                allocator.destroy(traversal_node);
                                traversal_node = ntraversal_node;
                            } else {
                                allocator.destroy(node);
                            }
                        },
                        else => return err,
                    };
                },
                .actual => {},
            }
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
