const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (general_purpose_allocator.deinit()) @panic("found memory leaks");
    const gpa = general_purpose_allocator.allocator();

    var it = try std.process.argsWithAllocator(gpa);
    defer it.deinit();
    _ = it.next() orelse unreachable; // skip binary name
    const s_handle = it.next() orelse unreachable;
    var file_handle = try std.os.stringToHandle(s_handle);

    if (builtin.target.os.tag == .windows) {
        // windows.HANDLE_FLAG_INHERIT is enabled
        var handle_flags: windows.DWORD = undefined;
        try windows.GetHandleInformation(file_handle, &handle_flags);
        try std.testing.expect(handle_flags & windows.HANDLE_FLAG_INHERIT != 0);
    } else {
        // FD_CLOEXEC is not set
        var fcntl_flags = try std.os.fcntl(file_handle, std.os.F.GETFD, 0);
        try std.testing.expect((fcntl_flags & std.os.FD_CLOEXEC) == 0);
    }

    try std.os.disableInheritance(file_handle);
    var file_in = std.fs.File{ .handle = file_handle }; // read side of pipe
    defer file_in.close();
    const file_in_reader = file_in.reader();
    const message = try file_in_reader.readUntilDelimiterAlloc(gpa, '\x17', 20_000);
    defer gpa.free(message);
    try std.testing.expectEqualSlices(u8, message, "test123");
}
