const builtin = @import("builtin");
const std = @import("std");
const ChildProcess = std.ChildProcess;
const math = std.math;
const windows = std.os.windows;
const os = std.os;
const testing = std.testing;
const child_process = std.child_process;
const pipe_rd = os.pipe_rd;
const pipe_wr = os.pipe_wr;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) @panic("found memory leaks");
    const gpa = gpa_state.allocator();

    var it = try std.process.argsWithAllocator(gpa);
    defer it.deinit();
    _ = it.next() orelse unreachable; // skip binary name
    const child_path = it.next() orelse unreachable;

    var pipe = try child_process.portablePipe();

    // write read side of pipe to string + add to spawn command
    var buf: [os.handleCharSize]u8 = comptime [_]u8{0} ** os.handleCharSize;
    const s_handle = try os.handleToString(pipe[pipe_rd], &buf);
    var child_proc = ChildProcess.init(
        &.{ child_path, s_handle },
        gpa,
    );

    // enabling of file inheritance directly before and closing directly after spawn
    // less time to leak => better
    {
        // Besides being faster to spawn, posix_spawn enables to close pipe[pipe_wr]
        // within the child before it is closed from Kernel after execv.
        // Note, that posix_spawn is executed in the child, so it does not allow
        // to minimize the leaking time of the parent's handle side.
        if (os.hasPosixSpawn) child_proc.posix_actions = try os.posix_spawn.Actions.init();
        defer if (os.hasPosixSpawn) child_proc.posix_actions.?.deinit();
        if (os.hasPosixSpawn) try child_proc.posix_actions.?.close(pipe[pipe_wr]);

        try os.enableInheritance(pipe[pipe_rd]);
        defer os.close(pipe[pipe_rd]);

        try child_proc.spawn();
    }

    // check that inheritance was disabled for the handle the whole time
    if (builtin.target.os.tag == .windows) {
        var handle_flags: windows.DWORD = undefined;
        try windows.GetHandleInformation(pipe[pipe_wr], &handle_flags);
        std.debug.assert(handle_flags & windows.HANDLE_FLAG_INHERIT == 0);
    } else {
        const fcntl_flags = try os.fcntl(pipe[pipe_wr], os.F.GETFD, 0);
        try std.testing.expect((fcntl_flags & os.FD_CLOEXEC) != 0);
    }

    var file_out = std.fs.File{ .handle = pipe[pipe_wr] };
    defer file_out.close();
    const file_out_writer = file_out.writer();
    try file_out_writer.writeAll("test123\x17"); // ETB = \x17
    const ret_val = try child_proc.wait();
    try testing.expectEqual(ret_val, .{ .Exited = 0 });
}
