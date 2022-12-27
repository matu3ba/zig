const builtin = @import("builtin");
const std = @import("std");
const ChildProcess = std.ChildProcess;
const math = std.math;
const windows = std.os.windows;
const os = std.os;
const testing = std.testing;

fn testPipeInfo(self: *ChildProcess) ChildProcess.SpawnError!void {
    const windowsPtrDigits: usize = std.math.log10(math.maxInt(usize));
    const otherPtrDigits: usize = std.math.log10(math.maxInt(u32)) + 1; // +1 for sign
    if (self.extra_streams) |extra_streams| {
        for (extra_streams) |*extra| {
            const size = comptime size: {
                if (builtin.target.os.tag == .windows) {
                    break :size windowsPtrDigits;
                } else {
                    break :size otherPtrDigits;
                }
            };
            var buf = comptime [_]u8{0} ** size;
            var s_chpipe_h: []u8 = undefined;
            std.debug.assert(extra.direction == .parent_to_child);
            const handle = handle: {
                if (builtin.target.os.tag == .windows) {
                    // handle is *anyopaque and there is no other way to cast
                    break :handle @ptrToInt(extra.*.input.?.handle);
                } else {
                    break :handle extra.*.input.?.handle;
                }
            };
            s_chpipe_h = std.fmt.bufPrint(
                buf[0..],
                "{d}",
                .{handle},
            ) catch unreachable;
            try self.stdin.?.writer().writeAll(s_chpipe_h);
            try self.stdin.?.writer().writeAll("\n");
        }
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) @panic("found memory leaks");
    const gpa = gpa_state.allocator();

    var it = try std.process.argsWithAllocator(gpa);
    defer it.deinit();
    _ = it.next() orelse unreachable; // skip binary name

    {
        // 1. setup extra pipe with parsing stdin pipe
        const child_stdinpipe_path = it.next() orelse unreachable; // child_stdinpipe.zig
        var child_process = ChildProcess.init(
            &.{child_stdinpipe_path},
            gpa,
        );
        child_process.stdin_behavior = .Pipe;
        var extra_streams = [_]ChildProcess.ExtraStream{
            .{
                .direction = .parent_to_child,
                .input = null,
                .output = null,
            },
        };
        child_process.extra_streams = &extra_streams;
        // contains cleanup code for extra_streams
        try child_process.spawn(.{ .pipe_info_fn = testPipeInfo });
        try std.testing.expect(child_process.extra_streams.?[0].input == null);
        if (builtin.target.os.tag == .windows) {
            var handle_flags: windows.DWORD = undefined;
            try windows.GetHandleInformation(child_process.extra_streams.?[0].output.?.handle, &handle_flags);
            std.debug.assert(handle_flags & windows.HANDLE_FLAG_INHERIT != 0);
        } else {
            const fcntl_flags = try os.fcntl(child_process.extra_streams.?[0].output.?.handle, os.F.GETFD, 0);
            try std.testing.expect((fcntl_flags & os.FD_CLOEXEC) != 0);
        }

        const extra_str_wr = child_process.extra_streams.?[0].output.?.writer();
        try extra_str_wr.writeAll("test123\x17"); // ETB = \x17
        const ret_val = try child_process.wait();
        try testing.expectEqual(ret_val, .{ .Exited = 0 });
    }
    {
        // 2. setup extra pipe with parsing stdin
        const child_stdin_path = it.next() orelse unreachable; // child_stdin.zig
        _ = child_stdin_path;
        // TODO -- setup pipe --
        // var child_process = ChildProcess.init(
        //     &.{child_stdin_path},
        //     gpa,
        // );
        // var extra_streams = [_]ChildProcess.ExtraStream{
        //     .{
        //         .direction = .parent_to_child,
        //         .input = null,
        //         .output = null,
        //     },
        // };
        // child_process.extra_streams = &extra_streams;
        // try child_process.spawn(.{});
        // // TODO -- close pipe end --
        // try std.testing.expect(child_process.extra_streams.?[0].input == null);
        // if (builtin.target.os.tag == .windows) {
        //     var handle_flags: windows.DWORD = undefined;
        //     try windows.GetHandleInformation(child_process.extra_streams.?[0].output.?.handle, &handle_flags);
        //     std.debug.assert(handle_flags & windows.HANDLE_FLAG_INHERIT != 0);
        // } else {
        //     const fcntl_flags = try os.fcntl(child_process.extra_streams.?[0].output.?.handle, os.F.GETFD, 0);
        //     try std.testing.expect((fcntl_flags & os.FD_CLOEXEC) != 0);
        // }

        // const extra_str_wr = child_process.extra_streams.?[0].output.?.writer();
        // try extra_str_wr.writeAll("test123\x17"); // ETB = \x17
        // const ret_val = try child_process.wait();
        // try testing.expectEqual(ret_val, .{ .Exited = 0 });
    }
    {
        // 3. setup extra pipe with parsing environment variable
        const child_env_path = it.next() orelse unreachable; // child_stdin.zig
        _ = child_env_path;
    }
}
