const std = @import("std");

const VectorError = error{
    IndexOutOfRange,
};

/// A vector implementation (indexed; constant time lookup)
/// memory grows in increments of `DEFAULT_INIT_CAPACITY`
/// however, the underlying implementation is based on `@memcpy`
/// requiring >= 2N memory to successfully grow the vector
/// not ideal for memory constrained environments
pub fn ArrayVector(comptime T: type) type {
    return struct {
        ptr: []T,
        len: usize = 0,
        comptime t: type = T,

        const DEFAULT_INIT_CAPACITY = 5;

        pub fn init(allocator: std.mem.Allocator) !ArrayVector(T) {
            const ptr = try allocator.alloc(T, DEFAULT_INIT_CAPACITY);
            errdefer allocator.free(ptr);
            return ArrayVector(T){
                .ptr = ptr,
                .len = 0,
            };
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !ArrayVector(T) {
            const ptr = try allocator.alloc(T, capacity);
            errdefer allocator.free(ptr);
            return ArrayVector(T){
                .ptr = ptr,
                .len = 0,
            };
        }

        pub fn initWithContents(allocator: std.mem.Allocator, comptime init_list: []const T) !ArrayVector(T) {
            const ptr = try allocator.alloc(T, @divCeil(init_list.len, DEFAULT_INIT_CAPACITY) * DEFAULT_INIT_CAPACITY);
            errdefer allocator.free(ptr);
            @memcpy(ptr[0..init_list.len], init_list);
            return ArrayVector(T){
                .ptr = ptr,
                .len = init_list.len,
            };
        }

        pub fn deinit(self: *const ArrayVector(T), allocator: std.mem.Allocator) void {
            allocator.free(self.ptr);
        }

        pub fn eql(self: *const ArrayVector(T), other: *const ArrayVector(T)) bool {
            return (self.len == other.len and std.mem.eql(T, self.ptr[0..self.len], other.ptr[0..other.len]));
        }

        fn _grow(self: *ArrayVector(T), allocator: std.mem.Allocator) !void {
            var ptr = try allocator.alloc(T, self.ptr.len + DEFAULT_INIT_CAPACITY);
            errdefer allocator.free(ptr);
            @memcpy(ptr[0..self.ptr.len], self.ptr);
            const old_ptr = self.ptr;
            self.ptr = ptr;
            allocator.free(old_ptr);
        }

        /// returns the value help by the vector at index `i`
        /// returns `VectorError.IndexOutOfRange` if i < 0 or i >= length (zero indexing)
        pub fn at(self: *const ArrayVector(T), i: usize) VectorError!T {
            return if (i < self.len) self.ptr[i] else VectorError.IndexOutOfRange;
        }

        pub fn as_slice(self: *ArrayVector(T)) []T {
            return self.ptr[0..self.len];
        }

        pub fn as_const_slice(self: *const ArrayVector(T)) []const T {
            return self.ptr[0..self.len];
        }

        /// return true/false based on if the vector contains any data
        pub fn empty(self: *const ArrayVector(T)) bool {
            return (self.len == 0);
        }

        /// inserts the element `e` at index `i`
        /// shifting over all elements to the right
        /// allocates more memory for the vector if necessary
        pub fn insert(self: *ArrayVector(T), allocator: std.mem.Allocator, e: T, i: usize) !void {
            if (i >= self.len) return VectorError.IndexOutOfRange;
            if (self.len == self.ptr.len) {
                // when we need to grow the vector buffer
                // we can save ourselves a copy by copying vector contents
                // to their final positions in the new buffer
                var ptr = try allocator.alloc(T, self.ptr.len + DEFAULT_INIT_CAPACITY);
                errdefer allocator.free(ptr);
                @memcpy(ptr[0..i], self.ptr[0..i]);
                @memcpy(ptr[(i + 1)..(self.len + 1)], self.ptr[i..self.len]);
                const old_ptr = self.ptr;
                self.ptr = ptr;
                allocator.free(old_ptr);
            } else {
                // memcpy requires non-overlapping addresses
                // thus we require an intermediary buffer to shift all elements over
                const tmp = try allocator.alloc(T, self.len - i);
                defer allocator.free(tmp);
                @memcpy(tmp, self.ptr[i..self.len]);
                @memcpy(self.ptr[(i + 1)..(self.len + 1)], tmp);
            }
            self.ptr[i] = e;
            self.len += 1;
        }

        /// add element `e` at the end of our list
        /// increasing vector memory if necessary
        pub fn push_back(self: *ArrayVector(T), allocator: std.mem.Allocator, e: T) !void {
            if (self.len == self.ptr.len) try self._grow(allocator);
            self.ptr[self.len] = e;
            self.len += 1;
        }

        /// remove the item at index `i` and shifts over all elements at >`i`
        /// if this operation leaves enough empty capacity at the end of the vector
        /// shrink the vector
        pub fn erase(self: *ArrayVector(T), allocator: std.mem.Allocator, i: usize) !T {
            if (i >= self.len) return VectorError.IndexOutOfRange;
            const v = self.ptr[i];
            if (self.ptr.len - self.len >= DEFAULT_INIT_CAPACITY * 2 - 1) {
                const ptr = try allocator.alloc(T, self.ptr.len - DEFAULT_INIT_CAPACITY);
                if (i == self.len - 1) {
                    @memcpy(ptr[0 .. self.len - 1], self.ptr[0 .. self.len - 1]);
                } else {
                    // if we need to reallocate memory, we can save a copy
                    // by assembling the new vector in the new memory location
                    @memcpy(ptr[0..i], self.ptr[0..i]);
                    @memcpy(ptr[i .. self.len - 1], self.ptr[i + 1 .. self.len]);
                }
                const old_ptr = self.ptr;
                self.ptr = ptr;
                allocator.free(old_ptr);
            } else if (i < self.len - 1) {
                // we need to shift over all the elements to the right of i
                // memcpy does not allow overlapping memory addresses
                // so we need to copy it into a temporary buffer
                const ptr = try allocator.alloc(T, self.len - i - 1);
                defer allocator.free(ptr);
                @memcpy(ptr, self.ptr[i + 1 .. self.len]);
                @memcpy(self.ptr[i .. self.len - 1], ptr);
            }
            // if we are removing the last element of the list
            // and we don't need to reallocate memory
            // then we can simply decrement the length
            // leaving the data inplace
            self.len -= 1;
            return v;
        }

        /// remove the last element of the vector
        /// reducing the vector memory if needed
        pub fn pop(self: *ArrayVector(T), allocator: std.mem.Allocator) !T {
            return self.erase(allocator, self.len - 1);
        }
    };
}

// verify the array can grow, shrink and allocate/deallocate memory properly
test "test_growth_and_shrink" {
    const allocator = std.testing.allocator;
    var arr = try ArrayVector(u8).init(allocator);
    defer arr.deinit(allocator);

    // validate starting state
    try std.testing.expectEqual(5, arr.ptr.len);
    try std.testing.expect(arr.empty());

    // grow the array by 11
    const expected = "watermelons";
    for (expected) |c| {
        try arr.push_back(allocator, c);
    }
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(11, arr.len);
    try std.testing.expectEqualStrings(expected, arr.as_const_slice());

    // shrink the array to 5
    for (0..5) |_| {
        _ = try arr.pop(allocator);
    }
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(6, arr.len);

    _ = try arr.pop(allocator);
    try std.testing.expectEqual(10, arr.ptr.len);
    try std.testing.expectEqual(5, arr.len);
    try std.testing.expectEqualStrings("water", arr.as_const_slice());
}

test "test_init_with_capacity" {
    const allocator = std.testing.allocator;
    const arr = try ArrayVector(u8).initWithCapacity(allocator, 10);
    defer arr.deinit(allocator);

    try std.testing.expectEqual(10, arr.ptr.len);
    try std.testing.expect(arr.empty());
}

test "test_init_with_contents" {
    const allocator = std.testing.allocator;
    const arr = try ArrayVector(u8).initWithContents(allocator, "watermelons");
    defer arr.deinit(allocator);

    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(11, arr.len);
    try std.testing.expectEqualStrings("watermelons", arr.as_const_slice());
}

test "test_element_access" {
    const allocator = std.testing.allocator;
    const arr = try ArrayVector(u8).initWithContents(allocator, "watermelons");
    defer arr.deinit(allocator);

    for ("watermelon", 0..) |c, i| {
        try std.testing.expectEqual(c, try arr.at(i));
    }

    // test errors
    try std.testing.expectError(VectorError.IndexOutOfRange, arr.at(11));
}

test "test_insert" {
    const allocator = std.testing.allocator;
    var arr = try ArrayVector(u8).initWithContents(allocator, "watrmlons");
    defer arr.deinit(allocator);

    // validate initial state
    try std.testing.expectEqual(10, arr.ptr.len);
    try std.testing.expectEqual(9, arr.len);

    // insert without reallocating memory
    try arr.insert(allocator, 'e', 3);
    try std.testing.expectEqual(10, arr.ptr.len);
    try std.testing.expectEqual(10, arr.len);
    try std.testing.expectEqualStrings("watermlons", arr.as_const_slice());

    // insert and reallocate memory
    try arr.insert(allocator, 'e', 6);
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(11, arr.len);
    try std.testing.expectEqualStrings("watermelons", arr.as_const_slice());

    // test errors
    try std.testing.expectError(VectorError.IndexOutOfRange, arr.insert(allocator, 'e', 11));
}

test "test_erase" {
    const allocator = std.testing.allocator;
    var arr = try ArrayVector(u8).initWithContents(allocator, "watermelons");
    defer arr.deinit(allocator);

    // validate initial state
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(11, arr.len);

    // erase end character without reallocating array
    try std.testing.expectEqual('s', try arr.pop(allocator));
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(10, arr.len);
    try std.testing.expectEqualStrings("watermelon", arr.as_const_slice());

    // erase middle character without erallocating array
    try std.testing.expectEqual('e', try arr.erase(allocator, 3));
    try std.testing.expectEqual(15, arr.ptr.len);
    try std.testing.expectEqual(9, arr.len);
    try std.testing.expectEqualStrings("watrmelon", arr.as_const_slice());

    // trim down our array up until just before requiring reallocation
    for (0..3) |_| {
        _ = try arr.pop(allocator);
    }

    // erase middle character and reallocate array
    try std.testing.expectEqual('m', try arr.erase(allocator, 4));
    try std.testing.expectEqual(10, arr.ptr.len);
    try std.testing.expectEqual(5, arr.len);
    try std.testing.expectEqualStrings("watre", arr.as_const_slice());

    // test errors
    try std.testing.expectError(VectorError.IndexOutOfRange, arr.erase(allocator, 5));
}
