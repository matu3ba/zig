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
/// Fixed point number x = s * n * (b^f), so each digit is in [0to(b-1)], the
/// factor describes the amounts of digits after the dot and nominator is the
/// number without scaling with (b^f).
/// TODO: hardware detection + figure out how the hw instructions on x86 work
pub fn FixPointNumber(
    comptime sign: std.builtin.Signedness,
    comptime nominator_bit_cnt: u15,
    comptime base: u8,
    comptime factor: comptime_int,
) type {
    comptime assert(factor >= 0);
    comptime assert(base >= 2);

    return struct {
        data: std.meta.Int(sign, nominator_bit_cnt),

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

        pub fn init(from: type) void {
            const FromT = @TypeOf(from);
            comptime assert(FromT == .Float or FromT == .Int);
            switch (@typeInfo(FromT)) {
                .Int => |t_info| {
                    switch (t_info.signedness) {
                        .unsigned => {},
                        .signed => {},
                    }
                    // t_info.bits
                },
                .Float => {},
                else => unreachable,
            }
        }

        pub fn to(comptime T: type) T {}
        pub fn checkedTo(comptime T: type) !T {}
        pub fn lossyTo(comptime T: type) T {}

        // TODO: These are the tricky ones with comptime, since
        // we must do comptime field acess according to our layout
        // TODO: How much validation do we want to do?
        pub fn add(comptime T: type) !T {}
        pub fn sub(comptime T: type) !T {}
        pub fn mul(comptime T: type) !T {}

        // Division is slow.
        pub fn division(comptime T: type) !T {}

        // TODO more operations.
    };
}

test "sizes typeA binary floating point number" {
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
    // try testing.expect(@typeInfo(Bin_i1).Struct.fields[0].type == i1);
    // try testing.expect(@typeInfo(Bin_u1).Struct.fields[0].type == u1);
}
