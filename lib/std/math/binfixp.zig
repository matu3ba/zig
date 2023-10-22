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

// simplified powi for positive exponents, base > 0
fn powi(comptime base: comptime_int, comptime exp: comptime_int) comptime_int {
    assert(exp >= 0);
    var _exp = exp;
    var _base = base;
    var acc: comptime_int = 1;
    while (_exp > 1) {
        if (_exp & 1 == 1) {
            acc = acc * _base;
        }
        _exp /= 2;
        _base = _base * _base;
    }

    // Deal with the final bit of the exponent separately, since
    // squaring the _base afterwards is not necessary and may cause a
    // needless overflow.
    if (_exp == 1) {
        acc = acc * _base;
    }
    return acc;
}

/// Returns arbitrary fixed point number methods including comptime-introspection.
/// Fixed point number x = s * n * (b^f), so each digit is in [0,(b-1)], the
/// factor describes the amounts of digits after the dot and nominator n is the
/// number without scaling with (b^f).
///
/// Values can be set and get in the base number system ('getBase', 'setBase')
/// or in the fixed-point ('getFp', 'setFp') or with the according checked
/// ('getBaseChecked', ..) and lossy methods ('getBaseLossy', ..).
///
/// Consider 'x = + * 8 *(10^2)'. Then [0..max(u3)]*100 is the assignable range.
/// For (10^-2), [0..max(u3)]/100 is the assignable range.
/// 'setBase' would then set [0..max(u3)], whereas 'setFp' would set for the
/// former scale fp=(base*100) and internally base=(fp/100).
/// 'getBase' and 'getFp' work likewise.
///
/// Internally, digits are repesented as power of two, so for exmaple the number
/// 19 in decimal has the underlying representation 0b0001_1001.
/// Customized, more space efficient base encodings, like wise by IBM hardware
/// for decimals are not supported to keep the code simple.
///
/// TODO: explain how user must deal with loss of precision
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

        pub fn setBase(fpn: *Fpn, from: anytype) void {
            _ = from;
            _ = fpn;
        }

        pub fn getBase(fpn: *Fpn, from: anytype) void {
            _ = from;
            _ = fpn;
        }

        pub fn setFp(fpn: *Fpn, from: anytype) void {
            _ = from;
            _ = fpn;
        }

        pub fn getFp(fpn: *Fpn, from: anytype) void {
            _ = from;
            _ = fpn;
        }

        // TODO min, max

        /// This comptime checks that range of init type fits into the range
        /// and may prevent valid runtime initializations as it is optimized
        /// for no overhead and safety.
        ///
        /// Potential unsafe initialization can use direct field access.
        pub fn set(fpn: *Fpn, comptime is_fp: bool, from: anytype) void {
            const FromTI = @typeInfo(@TypeOf(from));
            const powi_base_fac = powi(base, factor);
            // std.math.powi(comptime_int, base, factor) catch unreachable;

            if (!@inComptime()) { // check that number in range of type, if runtime called
                comptime {
                    assert(FromTI == .Float or FromTI == .Int);
                    switch (FromTI) {
                        .Int => {
                            const min_int_scaled_from = std.math.minInt(@TypeOf(from)) * powi_base_fac;
                            const max_int_scaled_from = std.math.maxInt(@TypeOf(from)) * powi_base_fac;
                            if (min_int_scaled_from < std.math.minInt(DataT)) {
                                @compileLog("can not comptime guarantee range size fitting");
                                @compileLog(min_int_scaled_from, "<", std.math.minInt(DataT));
                            }
                            if (max_int_scaled_from > std.math.maxInt(DataT)) {
                                @compileLog("can not comptime guarantee range size fitting");
                                @compileLog(max_int_scaled_from, ">", std.math.maxInt(DataT));
                            }
                            // assert(std.math.minInt(@TypeOf(from)) * powi_base_fac >= std.math.minInt(DataT));
                            // assert(std.math.maxInt(@TypeOf(from)) * powi_base_fac <= std.math.maxInt(DataT));
                        },
                        .Float => {},
                        else => unreachable,
                    }
                }
            }

            if (@inComptime()) { // check that value in range of type, if comptime-known
                switch (FromTI) {
                    .Int => {
                        const mul_ov = @mulWithOverflow(from, powi_base_fac);
                        if (mul_ov[1] != 0) @compileLog(from, "*", powi_base_fac, "overflow");
                        // assert(from * powi_base_fac >= std.math.minInt(DataT), "@TypoeOf(DataT)");
                        if (mul_ov[0] < std.math.minInt(DataT)) {
                            @compileLog(from, "*", powi_base_fac, "<", std.math.minInt(DataT), DataT);
                        }
                        // assert(from * powi_base_fac <= std.math.maxInt(DataT), "@TypoeOf(DataT)");
                        if (mul_ov[0] > std.math.maxInt(DataT)) {
                            @compileLog(from, "*", powi_base_fac, ">", std.math.maxInt(DataT), DataT);
                        }
                    },
                    .Float => {},
                    else => unreachable,
                }
            }

            // TODO decimal, because this only implements binary
            if (is_fp) {
                fpn.data = from;
            } else {
                fpn.data = from * powi_base_fac;
            }
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

        pub fn add(fpn1: Fpn, fpn2: Fpn) Fpn {
            // std.debug.print("fpn1: {}, fpn2: {}\n", .{ @TypeOf(fpn1.data), @TypeOf(fpn2.data) });
            // std.debug.print("fpn1: {d}, fpn2: {d}\n", .{ fpn1.data, fpn2.data });
            return Fpn{
                .data = fpn1.data + fpn2.data,
            };
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

test "add typeA_bin typeB_bin typeA_dec typeB_dec" {
    const Bin_i6_2 = FixPointNumber(.signed, 6, 2, 0); // i6 with 2**0=1 as factor
    const Bin_i6_2_2 = FixPointNumber(.signed, 6, 2, 2); // i6 with 2**2 as factor
    // const Dec_i6_2 = FixPointNumber(.signed, 10, 10, 0);

    comptime {
        { // add typeA_bin typeA_bin
            var bi6_n1: Bin_i6_2 = undefined;
            var bi6_n2: Bin_i6_2 = undefined;
            bi6_n1.init(@as(u5, 10));
            bi6_n2.init(@as(u5, 11));
            const res_typeA_bin = bi6_n1.add(bi6_n2);
            assert(res_typeA_bin.data == 21);
        }
        { // add typeB_bin typeB_bin
            var bi6_2_n1: Bin_i6_2_2 = undefined;
            var bi6_2_n2: Bin_i6_2_2 = undefined;
            bi6_2_n1.init(@as(u6, 5));
            bi6_2_n2.init(@as(u6, 6));
            const res_typeB_bin = bi6_2_n1.add(bi6_2_n2);
            assert(res_typeB_bin.data == 11); // TODO scale up etc
        }
        // { // add typeB_bin typeA_bin
        //     var bi6_n1: Bin_i6_2 = undefined;
        //     var bi6_n2: Bin_i6_2 = undefined;
        //     bi6_n1.init(@as(u5, 10));
        //     bi6_n2.init(@as(u5, 11));
        //     const res_typeA_bin = bi6_n1.add(bi6_n2);
        //     assert(res_typeA_bin.data == 21);
        // }
    }

    { // add typeA_bin typeA_bin
        var bi6_n1: Bin_i6_2 = undefined;
        var bi6_n2: Bin_i6_2 = undefined;
        bi6_n1.init(@as(u5, 10));
        bi6_n2.init(@as(u5, 11));
        const res_typeA_bin = bi6_n1.add(bi6_n2);
        assert(res_typeA_bin.data == 21);
    }
}

test "sub typeA_bin typeB_bin typeA_dec typeB_dec" {
    comptime {
        // sub typeA_bin typeA_bin
        // ..
    }

    // sub typeA_bin typeA_bin
    // ..
}

test "mul typeA_bin typeB_bin typeA_dec typeB_dec" {
    comptime {
        // mul typeA_bin typeA_bin
        // ..
    }

    // mul typeA_bin typeA_bin
    // ..
}

test "div typeA_bin typeB_bin typeA_dec typeB_dec" {
    comptime {
        // div typeA_bin typeA_bin
        // ..
    }

    // div typeA_bin typeA_bin
    // ..
}

// TODO how to infer result location type with @as() ?
// pub fn getBase(fpn: *Fpn, from: anytype) anytype {
//     _ = from;
//     _ = fpn;
//
// }
