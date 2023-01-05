const builtin = @import("builtin");
const std = @import("std");
const ChildProcess = std.ChildProcess;
const math = std.math;
const windows = std.os.windows;
const os = std.os;
const testing = std.testing;
const child_process = std.child_process;

const windowsPtrDigits: usize = std.math.log10(math.maxInt(usize));
const otherPtrDigits: usize = std.math.log10(math.maxInt(u32)) + 1; // +1 for sign
const handleCharSize = if (builtin.target.os.tag == .windows) windowsPtrDigits else otherPtrDigits;

/// assert: buf can store the handle
fn handleToString(handle: os.fd_t, buf: []u8) std.fmt.BufPrintError![]u8 {
    var s_handle: []u8 = undefined;
    const handle_int =
        // handle is *anyopaque or an integer on unix-likes Kernels.
        if (builtin.target.os.tag == .windows) @ptrToInt(handle) else handle;
    s_handle = try std.fmt.bufPrint(buf[0..], "{d}", .{handle_int});
    return s_handle;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) @panic("found memory leaks");
    const gpa = gpa_state.allocator();

    var it = try std.process.argsWithAllocator(gpa);
    defer it.deinit();
    _ = it.next() orelse unreachable; // skip binary name
    const child_path = it.next() orelse unreachable;

    // use posix convention: 0 read, 1 write
    var pipe: if (builtin.os.tag == .windows) [2]windows.HANDLE else [2]os.fd_t = undefined;
    if (builtin.os.tag == .windows) {
        const saAttr = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.TRUE,
            .lpSecurityDescriptor = null,
        };
        // create pipe and enable inheritance for the read end, which will be given to the child
        try child_process.windowsMakeAsyncPipe(&pipe[0], &pipe[1], &saAttr, .parent_to_child);
    } else {
        pipe = try os.pipe(); // leaks on default, but more portable, TODO: use pip2 and close earlier?
    }

    // write read side of pipe to string + add to spawn command
    var buf: [handleCharSize]u8 = comptime [_]u8{0} ** handleCharSize;
    const s_handle = try handleToString(pipe[0], &buf);
    var child_proc = ChildProcess.init(
        &.{ child_path, s_handle },
        gpa,
    );
    {
        // close read side of pipe, less time for leaking, if closed immediately
        if (os.hasPosixSpawn) child_proc.posix_actions = try os.posix_spawn.Actions.init();
        defer if (os.hasPosixSpawn) child_proc.posix_actions.?.deinit();
        if (os.hasPosixSpawn) try child_proc.posix_actions.?.close(pipe[1]); // TODO: This is not closed in child
        defer os.close(pipe[0]);

        try child_proc.spawn();
    }

    // call fcntl on Unixes to disable handle inheritance (windows one is per default not enabled)
    if (builtin.os.tag != .windows) {
        try std.os.disableFileInheritance(pipe[1]);
    }

    // windows does have inheritance disabled on default, but we check to be sure
    if (builtin.target.os.tag == .windows) {
        var handle_flags: windows.DWORD = undefined;
        try windows.GetHandleInformation(pipe[1].?, &handle_flags);
        std.debug.assert(handle_flags & windows.HANDLE_FLAG_INHERIT == 0);
    } else {
        const fcntl_flags = try os.fcntl(pipe[1], os.F.GETFD, 0);
        try std.testing.expect((fcntl_flags & os.FD_CLOEXEC) != 0);
    }

    var file_out = std.fs.File{ .handle = pipe[1] };
    defer file_out.close();
    const file_out_writer = file_out.writer();
    try file_out_writer.writeAll("test123\x17"); // ETB = \x17
    const ret_val = try child_proc.wait();
    try testing.expectEqual(ret_val, .{ .Exited = 0 });
}
