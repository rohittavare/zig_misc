const std = @import("std");

/// a totally normal function; despite including a loop
/// it is no problem to execute at comptime
/// because the function is called prefixed with the `comptime` prefix
fn comptime1(a: [4]u8) [5]u8 {
    var ret: [5]u8 = undefined;
    for (a, 0..) |c, i| {
        ret[i] = c;
    }
    ret[4] = 0;
    return ret;
}

test "comptime1" {
    const a: [4]u8 = @splat(4);
    const b = comptime comptime1(a);
    // we need to tell the compiler to run the comparison at compile-time
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

// however, when calling this function on module-level
// constants, we can omit the `comptime` keyword
const comptime1_1_a: [4]u8 = @splat(4);
const comptime1_1_b = comptime1(comptime1_1_a);

test "comptime1.1" {
    if (!comptime std.mem.eql(u8, &comptime1_1_b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// the same as `comptime1()` except
/// comptime is also applied to the parameter
/// despite all parameters being compile-time
/// caller still needs to specify the `comptime` prefix
fn comptime2(comptime a: [4]u8) [5]u8 {
    var ret: [5]u8 = undefined;
    for (a, 0..) |c, i| {
        ret[i] = c;
    }
    ret[4] = 0;
    return ret;
}

test "comptime2" {
    const a: [4]u8 = @splat(4);
    const b = comptime comptime2(a);
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

// same here as with test 1.1
const comptime2_1_a: [4]u8 = @splat(4);
const comptime2_1_b = comptime2(comptime2_1_a);

test "comptime2.1" {
    if (!comptime std.mem.eql(u8, &comptime2_1_b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// next we wrap the function body in a `comptime` block
/// despite this, we cannot return within this block
/// and still need caller to prefix `comptime` keyword
fn comptime3(comptime a: [4]u8) [5]u8 {
    var ret: [5]u8 = undefined;
    comptime {
        for (a, 0..) |c, i| {
            ret[i] = c;
        }
        ret[4] = 0;
    }
    return ret;
}

test "comptime3" {
    const a: [4]u8 = @splat(4);
    const b = comptime comptime3(a);
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// By making the function inline and wrapping the body
/// in a `comptime` block we automatically evaluate this function
/// at compile-time without the `comptime` keyword in the caller
inline fn comptime4(comptime a: [4]u8) [5]u8 {
    comptime {
        var ret: [5]u8 = undefined;
        for (a, 0..) |c, i| {
            ret[i] = c;
        }
        ret[4] = 0;
        return ret;
    }
}

test "comptime4" {
    const a: [4]u8 = @splat(4);
    const b = comptime4(a);
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// labeling inputs as comptime is also optional in this case
/// but the compiler will complain if you're using non-comptime values
/// in the comptime block, so the net effect is the same
/// just depends on whether the type-checker or compiler complains
inline fn comptime5(a: [4]u8) [5]u8 {
    comptime {
        var ret: [5]u8 = undefined;
        for (a, 0..) |c, i| {
            ret[i] = c;
        }
        ret[4] = 0;
        return ret;
    }
}

test "comptime5" {
    const a: [4]u8 = @splat(4);
    const b = comptime5(a);
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// `inline` keyword (even with comptime arguments)
/// is not sufficient to automatically evaluate at compile-time
inline fn comptime6(comptime a: [4]u8) [5]u8 {
    var ret: [5]u8 = undefined;
    for (a, 0..) |c, i| {
        ret[i] = c;
    }
    ret[4] = 0;
    return ret;
}

test "comptime6" {
    const a: [4]u8 = @splat(4);
    const b = comptime comptime6(a);
    if (!comptime std.mem.eql(u8, &b, &[5]u8{ 4, 4, 4, 4, 0 })) @compileError("the evaluation could not be completed at compile-time!");
}

/// at compile-time, slices need to be backed by literal arrays,
/// which have fixed length. However, with comptime-functions, we can
/// return arrays whose length are function of input array/slice length
inline fn comptime7(comptime a: []const u8) []const u8 {
    comptime {
        var tmp: [a.len + 1]u8 = @splat(0);
        for (a, 0..) |c, i| {
            tmp[i] = c;
        }
        tmp[a.len] = @as(u8, a.len + 1);
        return &tmp;
    }
}

test "comptime7" {
    comptime var a: []const u8 = ([_]u8{})[0..];
    inline for (0..5) |_| {
        a = comptime7(a);
    }
    if (!comptime std.mem.eql(u8, a, &[5]u8{ 1, 2, 3, 4, 5 })) @compileError("the evaluation could not be completed at compile-time!");
}
