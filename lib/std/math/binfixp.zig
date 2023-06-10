//! Fixed point numbers to provide comptime applicablility and user-control over
//! code size without having to deal with linker complexity.
//! Binary fixed point number x = s * n * (b^f)
//! s sign, n nominator, b base, f implicit factor as integer value
//! In contrast to floating point numbers, fixed-point infinites or NaNs are
//! not supported.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = std.builtin;

const Sign = enum {
    signed,
    unsigned,
};

/// Returns binary fixed point number methods including comptime-introspection.
/// Fixed point number x = s * n * (b^f), so each digit is in [0,(b-1)], the
/// factor describes the amounts of digits after the dot and nominator is the
/// number without scaling with (b^f).
/// TODO: hardware detection + figure out how the hw instructions on x86 work
pub fn FixPointNumber(
    comptime sign: std.builtin.Signedness,
    comptime nominator_bit_cnt: u15,
    comptime base: u8,
    comptime factor: comptime_int,
) type {
    const DataT = std.meta.Int(sign, nominator_bit_cnt);
    const base_bit_cnt = std.math.log2_int_ceil(u8, base);
    // const BaseT = std.meta.Int(.unsigned, base_bit_cnt);

    // check s|1111|...|1111|1111
    // for example 2**4-1 = 15 for decimal
    comptime {
        assert(factor >= 0);
        assert(base >= 2);
        var sign_bit_cnt = nominator_bit_cnt;
        if (sign == .signed) sign_bit_cnt -= 1;
        _ = std.math.divExact(comptime_int, sign_bit_cnt, base_bit_cnt) catch unreachable;
    }

    return struct {
        const Fpn = @This();

        data: DataT,

        pub fn cSign() std.builtin.Signedness {
            return sign;
        }
        pub fn cNominatorT() type {
            return std.meta.Int(sign, nominator_bit_cnt);
        }
        pub fn cBase() u8 {
            return base;
        }
        pub fn cFactor() comptime_int {
            return factor;
        }

        pub fn init(fpn: *Fpn, from: anytype) void {
            const FromTI = @typeInfo(@TypeOf(from));
            comptime assert(FromTI == .Float or FromTI == .Int);
            // TODO comptime check, if number if representable
            // switch (@typeInfo(FromTI)) {
            //     .Int => |t_info| {
            //         switch (t_info.signedness) {
            //             .unsigned => {},
            //             .signed => {},
            //         }
            //     },
            //     .Float => {},
            //     else => unreachable,
            // }
            fpn.data = from;
        }

        pub fn to(comptime T: type) T {
            // t1

        }
        pub fn checkedTo(comptime T: type) !T {
            // t1
        }
        pub fn lossyTo(comptime T: type) T {
            // t1

        }

        // TODO: These are the tricky ones with comptime, since
        // we must do comptime field acess according to our layout
        // TODO: How much validation do we want to do?
        pub fn add(comptime T: type) !T {
            // t1
        }
        // checkedAdd
        // lossyAdd
        pub fn sub(comptime T: type) !T {
            // t1
        }
        // checkedMul
        // lossyMul
        pub fn mul(comptime T: type) !T {
            // t1
        }
        // checkedMul
        // lossyMul
        // Division is slow.
        pub fn div(comptime T: type) !T {
            // t1
        }
        // checkedDiv
        // lossyDiv
        // TODO more operations?
    };
}

test "sizes typeA binary fixed-point number" {
    const Bin_u1 = FixPointNumber(.unsigned, 1, 2, 0);
    const Bin_i1 = FixPointNumber(.signed, 1, 2, 0);
    const Bin_u2 = FixPointNumber(.unsigned, 2, 2, 0);
    const Bin_i2 = FixPointNumber(.signed, 2, 2, 0);

    comptime {
        assert(@typeInfo(Bin_u1).Struct.fields[0].type == u1);
        assert(@typeInfo(Bin_i1).Struct.fields[0].type == i1);
        assert(@typeInfo(Bin_u2).Struct.fields[0].type == u2);
        assert(@typeInfo(Bin_i2).Struct.fields[0].type == i2);

        assert(Bin_u1.cSign() == .unsigned);
        assert(Bin_u1.cNominatorT() == u1);
        assert(Bin_u1.cBase() == @as(u32, 2));
        assert(Bin_u1.cFactor() == @as(u32, 0));
    }

    var biu1: Bin_u1 = undefined;
    const bu1: u1 = 1;
    biu1.init(bu1);

    // try testing.expect(@typeInfo(Bin_i1).Struct.fields[0].type == i1);
    // try testing.expect(@typeInfo(Bin_u1).Struct.fields[0].type == u1);
}

test "sizes typeB binary fixed-point number" {
    const Bin_u1_2 = FixPointNumber(.unsigned, 1, 2, 2);
    const Bin_i1_2 = FixPointNumber(.signed, 1, 2, 2);
    const Bin_u2_2 = FixPointNumber(.unsigned, 2, 2, 2);
    const Bin_i2_2 = FixPointNumber(.signed, 2, 2, 2);

    comptime {
        assert(@typeInfo(Bin_u1_2).Struct.fields[0].type == u1);
        assert(@typeInfo(Bin_i1_2).Struct.fields[0].type == i1);
        assert(@typeInfo(Bin_u2_2).Struct.fields[0].type == u2);
        assert(@typeInfo(Bin_i2_2).Struct.fields[0].type == i2);

        assert(Bin_u2_2.cSign() == .unsigned);
        assert(Bin_u2_2.cNominatorT() == u2);
        assert(Bin_u2_2.cBase() == @as(u32, 2));
        assert(Bin_u2_2.cFactor() == @as(u32, 2));
    }
}

test "size typeA decimal fixed-point number" {
    const Dec_u4_0 = FixPointNumber(.unsigned, 4, 10, 0);
    const Dec_i5_0 = FixPointNumber(.signed, 5, 10, 0);
    const Dec_u8_0 = FixPointNumber(.unsigned, 8, 10, 0);
    const Dec_i9_0 = FixPointNumber(.signed, 9, 10, 0);

    comptime {
        assert(@typeInfo(Dec_u4_0).Struct.fields[0].type == u4);
        assert(@typeInfo(Dec_i5_0).Struct.fields[0].type == i5);
        assert(@typeInfo(Dec_u8_0).Struct.fields[0].type == u8);
        assert(@typeInfo(Dec_i9_0).Struct.fields[0].type == i9);

        assert(Dec_u4_0.cSign() == .unsigned);
        assert(Dec_u4_0.cNominatorT() == u4);
        assert(Dec_u4_0.cBase() == @as(u32, 10));
        assert(Dec_u4_0.cFactor() == @as(u32, 0));
    }
}

test "size typeB decimal fixed-point number" {
    const Dec_u4_2 = FixPointNumber(.unsigned, 4, 10, 2);
    const Dec_i5_2 = FixPointNumber(.signed, 5, 10, 2);
    const Dec_u8_2 = FixPointNumber(.unsigned, 8, 10, 2);
    const Dec_i9_2 = FixPointNumber(.signed, 9, 10, 2);

    comptime {
        assert(@typeInfo(Dec_u4_2).Struct.fields[0].type == u4);
        assert(@typeInfo(Dec_i5_2).Struct.fields[0].type == i5);
        assert(@typeInfo(Dec_u8_2).Struct.fields[0].type == u8);
        assert(@typeInfo(Dec_i9_2).Struct.fields[0].type == i9);

        assert(Dec_u4_2.cSign() == .unsigned);
        assert(Dec_u4_2.cNominatorT() == u4);
        assert(Dec_u4_2.cBase() == @as(u32, 10));
        assert(Dec_u4_2.cFactor() == @as(u32, 2));
    }
}
