//!zig_spawn is posix_spawn minus the complex thread-local signal handling from posix threads
//!Note, that thread signaling and cancelation methods are not used.
//!zig_spawn is not multithreading-safe.
// TODO phrasing

//reasons:
//Support in musl and glibc is still incomplete.
//posix_spawn has several 1-line thread-unsafe set()/get() methods.
//pthreads has many thread-safe set()/get() methods, even though synchronization
//may be unnecessary.

// based on musl implementation of posix_spawn

const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const system = os.system;
const errno = system.getErrno;
const fd_t = system.fd_t;
const mode_t = system.mode_t;
const pid_t = system.pid_t;
const unexpectedErrno = os.unexpectedErrno;
const UnexpectedError = os.UnexpectedError;
const toPosixPath = os.toPosixPath;
const WaitPidResult = os.WaitPidResult;

pub usingnamespace zig_spawn;

pub const Error = error{
    SystemResources,
    InvalidFileDescriptor,
    NameTooLong,
    TooBig,
    PermissionDenied,
    InputOutput,
    FileSystem,
    FileNotFound,
    InvalidExe,
    NotDir,
    FileBusy,

    /// Returned when the child fails to execute either in the pre-exec() initialization step, or
    /// when exec(3) is invoked.
    ChildExecFailed,
} || UnexpectedError;

// TODO make this cross platform (pull in other symbols depending on libc/darwin)
pub const POSIX_SPAWN_RESETIDS = 0x0001;
pub const POSIX_SPAWN_SETPGROUP = 0x0002;
pub const POSIX_SPAWN_SETSIGDEF = 0x0004;
pub const POSIX_SPAWN_SETSIGMASK = 0x0008;
// The following ones are platform specific and glibc allows platforms to
// overwrite these, so define them per OS
pub const POSIX_SPAWN_SETSCHEDPARAM = 0x0010;
pub const POSIX_SPAWN_SETSCHEDULER = 0x0020;
pub const POSIX_SPAWN_USEVFORK = 0x0040;
pub const POSIX_SPAWN_SETSID = 0x0080;

pub const FDOP_CLOSE = 1;
pub const FDOP_DUP2 = 2;
pub const FDOP_OPEN = 3;
pub const FDOP_CHDIR = 4;
pub const FDOP_FCHDIR = 5;

const Fdop = struct {
    next: ?*Fdop,
    prev: ?*Fdop,
    cmd: c_int,
    fd: c_int,
    srcfd: c_int,
    oflag: c_int,
    mode: mode_t,
    path: []u8,
};

/// Configuration options for hints on how to spawn processes.
pub const SpawnConfig = struct {
    // TODO compile-time call graph analysis to determine stack upper bound
    // https://github.com/ziglang/zig/issues/157

    /// Size in bytes of the Process' stack
    stack_size: usize = 16 * 1024 * 1024,
};

const zig_spawn = struct {
    //typedef struct {
    // int __flags;
    // pid_t __pgrp;
    // sigset_t __def, __mask;
    // int __prio, __pol;
    // void *__fn;
    // char __pad[64-sizeof(void *)];
    //} posix_spawnattr_t;
    pub const Attr = struct {
        flags: u32, // musl uses int, darinw uses c_short
        pgrp: pid_t,
        // sigset_t is 128 bytes on 64 bit Linux, Linux reserves 1024 bit
        // https://unix.stackexchange.com/a/399356
        sigdef: system.sigset_t,
        sigmask: system.sigset_t,
        prio: i32, // unused in musl
        pol: i32, // unused in musl
        @"fn": ?*anyopaque, // *fn () requires a return type, which we dont know
        // do we need padding by 64-@sizeOf(void*) => usize?

        pub fn init() Attr {
            return Attr{
                .flags = 0,
                .pid = 0,
                .sigdef = 0,
                .mask = 0,
                .prio = 0,
                .pol = 0,
                .@"fn" = null, // does this compile?
            };
        }

        pub fn deinit(self: *Attr) void {
            self.* = undefined;
        }

        pub fn setDefaultFlags(self: *Attr, flags: u16) void {
            // TODO improve this for non-musl targets
            comptime {
                const all_flags =
                    POSIX_SPAWN_RESETIDS |
                    POSIX_SPAWN_SETPGROUP |
                    POSIX_SPAWN_SETSIGDEF |
                    POSIX_SPAWN_SETSIGMASK |
                    POSIX_SPAWN_SETSCHEDPARAM |
                    POSIX_SPAWN_SETSCHEDULER |
                    POSIX_SPAWN_USEVFORK |
                    POSIX_SPAWN_SETSID;
                if (flags & ~all_flags > 0) @compileError("invalid default fields");
            }
            self.flags = flags;
        }
    };

    // C layout with padding?
    pub const Actions = struct {
        // int __pad0[2]; padding?
        // can we make the following *fn () void by providing our own action functions?
        actions: ?*anyopaque, // void *__actions; => can we make this type safe?
        // int __pad[16]; paading?

        pub fn init() Error!Actions {
            return Actions{
                .actions = null,
            };
        }

        pub fn deinit(self: *Actions, alloc: std.mem.Allocator) void {
            // TODO fix the ugly musl code with sequence operator
            var op: ?*Fdop = self.actions;
            while (op) |opval| {
                alloc.free(opval);
                op = opval.next;
            }
            self.* = undefined;
        }

        //pub fn open(self: *Actions, fd: fd_t, path: []const u8, flags: u32, mode: mode_t) Error!void {
        //    const posix_path = try toPosixPath(path);
        //    return self.openZ(fd, &posix_path, flags, mode);
        //}

        //pub fn openZ(self: *Actions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: mode_t) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_addopen(&self.actions, fd, path, @bitCast(c_int, flags), mode))) {
        //        .SUCCESS => return,
        //        .BADF => return error.InvalidFileDescriptor,
        //        .NOMEM => return error.SystemResources,
        //        .NAMETOOLONG => return error.NameTooLong,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}

        //pub fn close(self: *Actions, fd: fd_t) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_addclose(&self.actions, fd))) {
        //        .SUCCESS => return,
        //        .BADF => return error.InvalidFileDescriptor,
        //        .NOMEM => return error.SystemResources,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        .NAMETOOLONG => unreachable,
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}

        //pub fn dup2(self: *Actions, fd: fd_t, newfd: fd_t) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_adddup2(&self.actions, fd, newfd))) {
        //        .SUCCESS => return,
        //        .BADF => return error.InvalidFileDescriptor,
        //        .NOMEM => return error.SystemResources,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        .NAMETOOLONG => unreachable,
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}

        //pub fn inherit(self: *Actions, fd: fd_t) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_addinherit_np(&self.actions, fd))) {
        //        .SUCCESS => return,
        //        .BADF => return error.InvalidFileDescriptor,
        //        .NOMEM => return error.SystemResources,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        .NAMETOOLONG => unreachable,
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}

        //pub fn chdir(self: *Actions, path: []const u8) Error!void {
        //    const posix_path = try toPosixPath(path);
        //    return self.chdirZ(&posix_path);
        //}

        //pub fn chdirZ(self: *Actions, path: [*:0]const u8) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_addchdir_np(&self.actions, path))) {
        //        .SUCCESS => return,
        //        .NOMEM => return error.SystemResources,
        //        .NAMETOOLONG => return error.NameTooLong,
        //        .BADF => unreachable,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}

        //pub fn fchdir(self: *Actions, fd: fd_t) Error!void {
        //    switch (errno(system.posix_spawn_file_actions_addfchdir_np(&self.actions, fd))) {
        //        .SUCCESS => return,
        //        .BADF => return error.InvalidFileDescriptor,
        //        .NOMEM => return error.SystemResources,
        //        .INVAL => unreachable, // the value of file actions is invalid
        //        .NAMETOOLONG => unreachable,
        //        else => |err| return unexpectedErrno(err),
        //    }
        //}
    };

    const Args = struct {
        p: [2]c_int,
        oldmask: os.sigset_t,
        path: []const u8,
        fa: *const Actions,
        attr: *Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    };

    pub fn spawn(
        path: []const u8,
        actions: ?Actions,
        attr: ?Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    ) Error!pid_t {
        const posix_path = try toPosixPath(path);
        return spawnZ(&posix_path, actions, attr, argv, envp);
    }

    pub fn spawnZ(
        path: [*:0]const u8,
        actions: ?Actions,
        attr: ?Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    ) Error!pid_t {
        var pid: pid_t = undefined;
        var stack: [1024 + os.PATH_MAX]u8 = undefined;

        // pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cs);
        var args = Args{
            .p = undefined,
            .path = path,
            .fa = actions,
            .attr = attr,
            .argv = argv,
            .envp = envp,
        };
        // guard page etc to prevent stack smashing?
        // pthread_sigmask(SIG_BLOCK, SIGALL_SET, &args.oldmask);
        //LOCK(__abort_lock);

        //if (pipe2(args.p, O_CLOEXEC)) {
        //	UNLOCK(__abort_lock);
        //	ec = errno;
        //	goto fail;
        //}

        const flags: u32 = system.CLONE.VM | system.CLONE.VFORK | system.SIG.CHLD;
        // Linux for now
        pid = system.clone(child(), @ptrToInt(stack.ptr) + @sizeOf(stack), flags, &args);
        // close(args.p[1]);
        // UNLOCK(__abort_lock);

        if (pid > 0) {
            waitpid(pid, 0);
        } else {
            @panic("could not start childprocess\n");
        }

        //if (pid > 0) {
        //      if (read(args.p[0], &ec, sizeof ec) != sizeof ec) ec = 0;
        //      else waitpid(pid, &(int){0}, 0);
        //} else {
        //      ec = -pid;
        //}

        //close(args.p[0]);
        //if (!ec && res) *res = pid; // error code and res == 0

        //fail:
        //pthread_sigmask(SIG_SETMASK, &args.oldmask, 0);
        //pthread_setcancelstate(cs, 0);
        //
        //return ec; or 0

        // TODO figure out why arguments are different
        //switch (system.getErrno(system.clone(
        //    child(),
        //    @ptrToInt(&mapped[stack_offset]),
        //    flags,
        //instead of &args, used are:
        //    &instance.thread.parent_tid,
        //    tls_ptr,
        //    &instance.thread.child_tid.value,
        //))) {
        //    .SUCCESS => return Impl{ .thread = &instance.thread },
        //    .AGAIN => return error.ThreadQuotaExceeded,
        //    .INVAL => unreachable,
        //    .NOMEM => return error.SystemResources,
        //    .NOSPC => unreachable,
        //    .PERM => unreachable,
        //    .USERS => unreachable,
        //    else => |err| return os.unexpectedErrno(err),
        //}
        //switch (errno(system.posix_spawn(
        //    &pid,
        //    path,
        //    if (actions) |a| &a.actions else null,
        //    if (attr) |a| &a.attr else null,
        //    argv,
        //    envp,
        //))) {
        //    .SUCCESS => return pid,
        //    .@"2BIG" => return error.TooBig,
        //    .NOMEM => return error.SystemResources,
        //    .BADF => return error.InvalidFileDescriptor,
        //    .ACCES => return error.PermissionDenied,
        //    .IO => return error.InputOutput,
        //    .LOOP => return error.FileSystem,
        //    .NAMETOOLONG => return error.NameTooLong,
        //    .NOENT => return error.FileNotFound,
        //    .NOEXEC => return error.InvalidExe,
        //    .NOTDIR => return error.NotDir,
        //    .TXTBSY => return error.FileBusy,
        //    .BADARCH => return error.InvalidExe,
        //    .BADEXEC => return error.InvalidExe,
        //    .FAULT => unreachable,
        //    .INVAL => unreachable,
        //    else => |err| return unexpectedErrno(err),
        //}
    }

    fn child() void {}

    //pub fn spawnp(
    //    file: []const u8,
    //    actions: ?Actions,
    //    attr: ?Attr,
    //    argv: [*:null]?[*:0]const u8,
    //    envp: [*:null]?[*:0]const u8,
    //) Error!pid_t {
    //    const posix_file = try toPosixPath(file);
    //    return spawnpZ(&posix_file, actions, attr, argv, envp);
    //}

    //pub fn spawnpZ(
    //    file: [*:0]const u8,
    //    actions: ?Actions,
    //    attr: ?Attr,
    //    argv: [*:null]?[*:0]const u8,
    //    envp: [*:null]?[*:0]const u8,
    //) Error!pid_t {
    //    var pid: pid_t = undefined;
    //    switch (errno(system.posix_spawnp(
    //        &pid,
    //        file,
    //        if (actions) |a| &a.actions else null,
    //        if (attr) |a| &a.attr else null,
    //        argv,
    //        envp,
    //    ))) {
    //        .SUCCESS => return pid,
    //        .@"2BIG" => return error.TooBig,
    //        .NOMEM => return error.SystemResources,
    //        .BADF => return error.InvalidFileDescriptor,
    //        .ACCES => return error.PermissionDenied,
    //        .IO => return error.InputOutput,
    //        .LOOP => return error.FileSystem,
    //        .NAMETOOLONG => return error.NameTooLong,
    //        .NOENT => return error.FileNotFound,
    //        .NOEXEC => return error.InvalidExe,
    //        .NOTDIR => return error.NotDir,
    //        .TXTBSY => return error.FileBusy,
    //        .BADARCH => return error.InvalidExe,
    //        .BADEXEC => return error.InvalidExe,
    //        .FAULT => unreachable,
    //        .INVAL => unreachable,
    //        else => |err| return unexpectedErrno(err),
    //    }
    //}

    /// Use this version of the `waitpid` wrapper if you spawned your child process using `zig_spawn`
    /// or `zig_spawnp` syscalls.
    /// See `std.os.waitpid` for an alternative if your child process was spawned via `fork` and
    /// `execve` method.
    /// See `std.os.posix_spawn.waitpid` for an alternative if your child process was spawned via
    /// `posix_spawn` and ``posix_spawnp` method.
    pub fn waitpid(pid: pid_t, flags: u32) Error!WaitPidResult {
        const Status = if (builtin.link_libc) c_int else u32;
        var status: Status = undefined;
        while (true) {
            const rc = system.waitpid(pid, &status, if (builtin.link_libc) @intCast(c_int, flags) else flags);
            switch (errno(rc)) {
                .SUCCESS => return WaitPidResult{
                    .pid = @intCast(pid_t, rc),
                    .status = @bitCast(u32, status),
                },
                .INTR => continue,
                .CHILD => return error.ChildExecFailed,
                .INVAL => unreachable, // Invalid flags.
                else => unreachable,
            }
        }
    }
};
