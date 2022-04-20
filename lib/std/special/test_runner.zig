//! Default test runner
//! assume: OS environment
//! assume: (sub)processes and multithreading possible
//! assume: IPC via pipes possible
//! assume: The order of test execution **must not matter**.
//!         User ensures global state is properly initialized and
//!         reset/cleaned up between test blocks.
//! assume: User does not need additional messages besides test_name + number
//! assume: ports 9084, 9085 usable for localhost tcp (Zig Test, ascii ZT: 90, 84)
//! assert: User writes only 1 expectPanic per test block.
//!         Improving this requires to keep track of expect* functions in test blocks
//!         in Compilation.zig and have a convention how to initialize shared state.

// unclear: are 2 binaries needed or can 1 binary have 2 panic handlers?
//          could the panic handler be given information where to write the panic?
//          should we generalize this concept at comptime?
// unclear: dedicated API or other checks to ensure things gets cleaned up?

// principle:
// 2 binaries: compiler and test_runner
// 1. compiler compiles main() in this file as test_runner
// 2. compiler spawns test_runner as subprocess
// 3. test_runner (control) spawns itself as subprocess (worker)
// 4. on panic or finishing, message is written to socket for control to read
//    (worker has a custom panic handler to write panic message to the socket)
// communication via 2 sockets:
//     - 1. testnumber testnumber_exitstatus msglen
//     - 2. testout with data
// copying the memory from tcp socket to pipe for error message is still necessary
// https://stackoverflow.com/questions/11847793/are-tcp-socket-handles-inheritable

// compiler
//    |  --spawns-->  control
//    |                  |       --spawn at testfn0-->                worker
//    |                  |      <--testout: testfn0_exit_status 0--      |
//    |                  |      <--testout: testfn1_exit_status 0--      |
//    |                  |                 ...                           |
//    |                  |      <--testout: testfnx_exit_status msglen-- |
//    |                  |      <--stdout: panic_msg--                   |
//    | (<--panic_msg--) |                                               |
//    |                  |      (--spawn at testfnx+1-->)                |
//    |                  |                                               |
// unclear: should we special case 1.panic_msg, 2. panic_msg+context ?

const std = @import("std");
const io = std.io;
const builtin = @import("builtin");

const net = std.x.net;
const os = std.x.os;
const ip = net.ip;
const tcp = net.tcp;
const IPv4 = os.IPv4;
const IPv6 = os.IPv6;
const Socket = os.Socket;
const Buffer = os.Buffer;
const have_ifnamesize = @hasDecl(std.os.system, "IFNAMESIZE"); // interface namesize
const ChildProcess = std.ChildProcess;

pub const io_mode: io.Mode = builtin.test_io_mode;

var log_err_count: usize = 0;

// TODO REVIEW: why is not std.math.max(3*MAX_PATH_BYTES, std.mem.page_size) used ?
// paths arg[0], arg[1], cwd with each using as worst case MAX_PATH_BYTES
// TODO tcp code sizes (provide stubs for worst case string representation)
var args_buffer: [3 * std.fs.MAX_PATH_BYTES + std.mem.page_size]u8 = undefined;
var args_allocator = std.heap.FixedBufferAllocator.init(&args_buffer);

const State = enum {
    Control,
    Worker,
};

// running on raw sockets is not possible without additional permissions
// https://squidarth.com/networking/systems/rc/2018/05/28/using-raw-sockets.html
// only alternative: tcp/udp
const TcpIo = struct {
    state: State,
    // ip always localhost (ie 127.0.0.1)
    port_ctrl: u16 = 9084,
    port_data: u16 = 9085,
    ctrl: union {
        listener: tcp.Listener,
        client: tcp.Client,
    },
    data: union {
        listener: tcp.Listener,
        client: tcp.Client,
    },
    addr_ctrl: ip.Address,
    addr_data: ip.Address,
    conn_ctrl: tcp.Connection,
    conn_data: tcp.Connection,

    fn setup(state: State) !TcpIo {
        var tcpio = TcpIo{
            .state = state,
            .ctrl = undefined,
            .data = undefined,
            .addr_ctrl = undefined,
            .addr_data = undefined,
            .conn_ctrl = undefined,
            .conn_data = undefined,
        };

        switch (state) {
            State.Control => {
                tcpio.ctrl = .{ .listener = try tcp.Listener.init(.ip, .{ .close_on_exec = true }) };
                tcpio.data = .{ .listener = try tcp.Listener.init(.ip, .{ .close_on_exec = true }) };
                try tcpio.ctrl.listener.bind(ip.Address.initIPv4(IPv4.unspecified, tcpio.port_ctrl));
                try tcpio.data.listener.bind(ip.Address.initIPv4(IPv4.unspecified, tcpio.port_data));
                try tcpio.ctrl.listener.listen(1);
                try tcpio.data.listener.listen(1);
                tcpio.addr_ctrl = try tcpio.ctrl.listener.getLocalAddress();
                tcpio.addr_data = try tcpio.data.listener.getLocalAddress();
                switch (tcpio.addr_ctrl) {
                    .ipv4 => |*ipv4| ipv4.host = IPv4.localhost,
                    .ipv6 => unreachable,
                }
                switch (tcpio.addr_data) {
                    .ipv4 => |*ipv4| ipv4.host = IPv4.localhost,
                    .ipv6 => unreachable,
                }
            },
            State.Worker => {
                tcpio.ctrl = .{ .client = try tcp.Client.init(.ip, .{ .close_on_exec = true }) };
                tcpio.data = .{ .client = try tcp.Client.init(.ip, .{ .close_on_exec = true }) };
                const s_localhost = "127.0.0.1"; // HACK around libstd
                const localhost = try IPv4.parse(s_localhost);
                tcpio.addr_ctrl = ip.Address.initIPv4(localhost, tcpio.port_ctrl);
                tcpio.addr_data = ip.Address.initIPv4(localhost, tcpio.port_data);
            },
        }
        return tcpio;
    }
};

// args 0:testbinary, 1:compilerbinary,
// [2-4: --worker, port_ctrl, port_data]
fn processArgs() State {
    const args = std.process.argsAlloc(args_allocator.allocator()) catch {
        @panic("Too many bytes passed over the CLI to the test runner");
    };
    const self_name = if (args.len >= 1) args[0] else if (builtin.os.tag == .windows) "test.exe" else "test";
    const zig_ext = if (builtin.os.tag == .windows) ".exe" else "";
    if (args.len < 2 or 3 < args.len) {
        std.debug.print("Usage: {s} path/to/zig{s}\n", .{ self_name, zig_ext });
        @panic("Wrong number of command line arguments");
    }
    var state = State.Control;
    if (args.len == 3) {
        if (!std.mem.eql(u8, args[2], "--worker")) {
            std.debug.print("Usage: {s} path/to/zig{s}\n", .{ self_name, zig_ext });
            @panic("Found args[2] != '--worker'");
        }
        state = State.Worker;
    }
    std.testing.test_runner_exe_path = args[0];
    std.testing.zig_exe_path = args[1];
    return state;
}

// args: path_to_testbinary, path_to_zigbinary, [--worker]
pub fn main() !void {
    if (!have_ifnamesize) return error.FAILURE;

    if (builtin.zig_backend != .stage1 and
        (builtin.zig_backend != .stage2_llvm or builtin.cpu.arch == .wasm32))
    {
        return main2() catch @panic("test failure");
    }
    var state = processArgs();
    var tcpio = TcpIo.setup(state) catch unreachable;

    const test_fn_list = builtin.test_functions;

    const cwd = std.process.getCwdAlloc(args_allocator.allocator()) catch {
        @panic("Too many bytes passed over the CLI to the test runner");
    }; // windows compatibility requires allocation
    std.debug.print("test_runner_exe_path: {s}\n", .{std.testing.test_runner_exe_path});
    std.debug.print("zig_exe_path: {s}\n", .{std.testing.zig_exe_path});
    std.debug.print("cwd: {s}\n", .{cwd});

    if (tcpio.state == State.Control) {
        const args = [_][]const u8{
            std.testing.test_runner_exe_path,
            std.testing.zig_exe_path,
            "--worker",
        };
        var child_proc = try ChildProcess.init(&args, std.testing.allocator);
        defer child_proc.deinit();
        try child_proc.spawn();
        std.debug.print("child_proc spawned:\n", .{});
        std.debug.print("args {s}\n", .{args});

        tcpio.conn_ctrl = try tcpio.ctrl.listener.accept(.{ .close_on_exec = true }); // accept is blocking
        tcpio.conn_data = try tcpio.data.listener.accept(.{ .close_on_exec = true }); // accept is blocking
        defer tcpio.conn_ctrl.deinit();
        defer tcpio.conn_data.deinit();
        std.debug.print("connections succesful\n", .{});

        // respawn child_process until we reach test_fn.len:
        //   after wait():
        //   if ret_val == 0
        //     print OK of all messages
        //   else
        //     if messages in ctrl empty:
        //       print unexpected panic during test: got no panic message(s)
        //     else
        //       if message == expected_message
        //         print OK of current test_fn (other OKs were printed by child_process)
        //         continue;
        //       else
        //         print fatal, got 'message', expected 'expected_message'
        //
        //
        // panic message formatting:
        // 1. panic message must be allocated
        // 2. ctrl: test_fn_number exit_code msglen msg ?
        // 3. alternative is to use data: msg

        const message = "hello world";
        var buf: [message.len + 1]u8 = undefined;
        var msg = Socket.Message.fromBuffers(&[_]Buffer{
            Buffer.from(buf[0 .. message.len / 2]),
            Buffer.from(buf[message.len / 2 ..]),
        });
        _ = try tcpio.conn_ctrl.client.readMessage(&msg, 0);
        try std.testing.expectEqualStrings(message, buf[0..message.len]);
        std.debug.print("comparison successful\n", .{});

        const ret_val = child_proc.wait();
        try std.testing.expectEqual(ret_val, .{ .Exited = 0 });
        std.debug.print("server exited\n", .{});

        for (test_fn_list) |test_fn, i|
            std.debug.print("{d} {s}\n", .{ i, test_fn.name });
    } else {
        try tcpio.ctrl.client.connect(tcpio.addr_ctrl);
        try tcpio.data.client.connect(tcpio.addr_data);

        const message = "hello world";
        _ = try tcpio.ctrl.client.writeMessage(Socket.Message.fromBuffers(&[_]Buffer{
            Buffer.from(message[0 .. message.len / 2]),
            Buffer.from(message[message.len / 2 ..]),
        }), 0);
        // 1. start at provided index
        // 2. run test
        // 3. see above
    } // state == State.Worker

    for (test_fn_list) |test_fn, i|
        std.debug.print("{d} {s}\n", .{ i, test_fn.name });

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var progress = std.Progress{
        .dont_print_on_dumb = true,
    };
    const root_node = progress.start("Test", test_fn_list.len);
    const have_tty = progress.terminal != null and progress.supports_ansi_escape_codes;

    var async_frame_buffer: []align(std.Target.stack_align) u8 = undefined;
    // TODO this is on the next line (using `undefined` above) because otherwise zig incorrectly
    // ignores the alignment of the slice.
    async_frame_buffer = &[_]u8{};

    var leaks: usize = 0;
    for (test_fn_list) |test_fn, i| {
        std.testing.allocator_instance = .{};
        defer {
            if (std.testing.allocator_instance.deinit()) {
                leaks += 1;
            }
        }
        std.testing.log_level = .warn;

        var test_node = root_node.start(test_fn.name, 0);
        test_node.activate();
        progress.refresh();
        if (!have_tty) {
            std.debug.print("{d}/{d} {s}... ", .{ i + 1, test_fn_list.len, test_fn.name });
        }
        const result = if (test_fn.async_frame_size) |size| switch (io_mode) {
            .evented => blk: {
                if (async_frame_buffer.len < size) {
                    std.heap.page_allocator.free(async_frame_buffer);
                    async_frame_buffer = std.heap.page_allocator.alignedAlloc(u8, std.Target.stack_align, size) catch @panic("out of memory");
                }
                const casted_fn = @ptrCast(fn () callconv(.Async) anyerror!void, test_fn.func);
                break :blk await @asyncCall(async_frame_buffer, {}, casted_fn, .{});
            },
            .blocking => {
                skip_count += 1;
                test_node.end();
                progress.log("SKIP (async test)\n", .{});
                if (!have_tty) std.debug.print("SKIP (async test)\n", .{});
                continue;
            },
        } else test_fn.func();

        if (result) |_| {
            ok_count += 1;
            test_node.end();
            if (!have_tty) std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                progress.log("SKIP\n", .{});
                if (!have_tty) std.debug.print("SKIP\n", .{});
                test_node.end();
            },
            else => {
                fail_count += 1;
                progress.log("FAIL ({s})\n", .{@errorName(err)});
                if (!have_tty) std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                if (builtin.zig_backend != .stage2_llvm) if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                };
                test_node.end();
            },
        }
    }
    root_node.end();
    if (ok_count == test_fn_list.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(std.log.Level.err)) {
        log_err_count += 1;
    }
    if (@enumToInt(message_level) <= @enumToInt(std.testing.log_level)) {
        std.debug.print("[{s}] ({s}): " ++ format ++ "\n", .{ @tagName(scope), @tagName(message_level) } ++ args);
    }
}

pub fn main2() anyerror!void {
    var skipped: usize = 0;
    var failed: usize = 0;
    // Simpler main(), exercising fewer language features, so that stage2 can handle it.
    for (builtin.test_functions) |test_fn| {
        test_fn.func() catch |err| {
            if (err != error.SkipZigTest) {
                failed += 1;
            } else {
                skipped += 1;
            }
        };
    }
    if (builtin.zig_backend == .stage2_wasm or
        builtin.zig_backend == .stage2_x86_64 or
        builtin.zig_backend == .stage2_llvm)
    {
        const passed = builtin.test_functions.len - skipped - failed;
        const stderr = std.io.getStdErr();
        writeInt(stderr, passed) catch {};
        stderr.writeAll(" passed; ") catch {};
        writeInt(stderr, skipped) catch {};
        stderr.writeAll(" skipped; ") catch {};
        writeInt(stderr, failed) catch {};
        stderr.writeAll(" failed.\n") catch {};
    }
    if (failed != 0) {
        return error.TestsFailed;
    }
}

fn writeInt(stderr: std.fs.File, int: usize) anyerror!void {
    const base = 10;
    var buf: [100]u8 = undefined;
    var a: usize = int;
    var index: usize = buf.len;
    while (true) {
        const digit = a % base;
        index -= 1;
        buf[index] = std.fmt.digitToChar(@intCast(u8, digit), .lower);
        a /= base;
        if (a == 0) break;
    }
    const slice = buf[index..];
    try stderr.writeAll(slice);
}
