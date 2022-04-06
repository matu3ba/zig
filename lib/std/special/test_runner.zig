//! Default test runner
//! assume: OS environment
//! assume: (sub)processes and multithreading possible
//! assume: IPC via pipes possible
//! assume: The order of test execution **must not matter**.
//!         User ensures global state is properly initialized and
//!         reset/cleaned up between test blocks.

// principle:
// 2 binaries: compiler and test_runner
// 1. compiler compiles main() in this file as test_runner
// 2. compiler spawns test_runner as subprocess
// 3. test_runner (control) spawns itself as subprocess (worker)
// 4. on panic or finishing, message is written to pipe for control to read
//    (worker has a custom panic handler to write panic message)
// communication via IPCs stdin, stdout, stderr, testout (exit code of each test block)

// compiler
//    | --spawns--> control
//    |                |       --spawn at testfn0-->                worker
//    |                |      <--testout: testfn_exit_status0 0--      |
//    |                |      <--testout: testfn_exit_status1 0--      |
//    |                |                 ...                           |
//    |                |      <--testout: testfn_exit_statusx msglen-- |
//    |                |      <--stdout: panic_msg--                   |
//    | <--(unexpected panic_msg) stderr: panic_msg+context(for CI)--  |
//    |                |       --spawn at testfnx+1-->                 |
//    |                |                                               |

// limitation: can test only 1 panic per test block (testfn)
// unclear: are 2 binaries needed or can 1 binary have 2 panic handlers?
// unclear: should there be a dedicated API or other checks to ensure stuff gets cleaned up?

const std = @import("std");
const io = std.io;
const builtin = @import("builtin");

pub const io_mode: io.Mode = builtin.test_io_mode;

var log_err_count: usize = 0;

// TODO REVIEW
// arg[0], arg[1], cwd should be 3*MAX_PATH_BYTES
// why is not std.math.max(3*MAX_PATH_BYTES, std.mem.page_size) used ?
// TODO missing explanation of sizes
var args_buffer: [3 * std.fs.MAX_PATH_BYTES + std.mem.page_size]u8 = undefined;
var args_allocator = std.heap.FixedBufferAllocator.init(&args_buffer);

const State = enum {
    Control,
    Worker,
};

// args 0:testbinary, 1:compilerbinary, nonpositional: --worker,
//      TODO later:
//      --trace FILE (includes timestamps),
//      --bench (IPC Kernel overhead can vary and is hard to measure),
//      --parallel (user-encoded dependencies),
fn processArgs() State {
    var state = State.Control;
    const args = std.process.argsAlloc(args_allocator.allocator()) catch {
        @panic("Too many bytes passed over the CLI to the test runner");
    };
    const self_name = if (args.len >= 1) args[0] else if (builtin.os.tag == .windows) "test.exe" else "test";
    const zig_ext = if (builtin.os.tag == .windows) ".exe" else "";
    if (args.len < 2 or 3 < args.len) {
        std.debug.print("Usage: {s} path/to/zig{s}\n", .{ self_name, zig_ext });
        @panic("Wrong number of command line arguments");
    }
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

//if (args.len < 2 or args.len > 3) {
//    const self_name = if (args.len >= 1) args[0] else if (builtin.os.tag == .windows) "test.exe" else "test";
//    const zig_ext = if (builtin.os.tag == .windows) ".exe" else "";
//    std.debug.print("Usage: {s} path/to/zig{s}\n", .{ self_name, zig_ext });
//    @panic("Wrong number of command line arguments");
//}

// TODO extend, --verbose etc?
// args: path_to_testbinary, path_to_zigbinary, [--worker]
pub fn main() void {
    if (builtin.zig_backend != .stage1 and
        (builtin.zig_backend != .stage2_llvm or builtin.cpu.arch == .wasm32))
    {
        return main2() catch @panic("test failure");
    }
    //TODO figure out, what requiers builtin guard: std.testing globals?
    //if (builtin.zig_backend == .stage1)
    const state = processArgs();
    _ = state;
    const test_fn_list = builtin.test_functions;

    const cwd = std.process.getCwdAlloc(args_allocator.allocator()) catch {
        @panic("Too many bytes passed over the CLI to the test runner");
    }; // windows compatibility requires allocation
    std.debug.print("cwd: {s}\n", .{cwd});
    std.debug.print("test_runner_exe_path: {s}\n", .{std.testing.test_runner_exe_path});
    std.debug.print("zig_exe_path: {s}\n", .{std.testing.zig_exe_path});

    if (state == State.Control) {
        // 1. child_process with --worker
        // 2. wait
        // 3. read testout from child_process (pipe) [status data_size_in_bytes\nstatus..]
        // 4. read stdout from child_process (pipe) [data(size_in_bytes),data(size_in_bytes)..]
        // 5. check exit status/signal status of child (OOM/error on cleanup ressources)
    } else {
        // 1. start at given index
        // 2. run test
        // 3. write exit status + data for test,
        //    - write to stdout/testout pipe or allocation can fail => special signal
        // x. on panic call custom panic handler to dump panic message
        //    to inherited stderr from compiler binary to dumb state to CI
    } // state == State.Worker
    // TODO: must exactly how many bytes were written to testout pipe
    // for each test to read in the associated stdout pipe

    for (test_fn_list) |test_fn, i|
        std.debug.print("{d} {s}\n", .{ i, test_fn.name });

    // TODO get binary path => tests child_process
    // TODO implement subprocess

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
