const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const child_stdinpipe = b.addExecutable("child_stdinpipe", "child_stdinpipe.zig");
    child_stdinpipe.setBuildMode(mode);
    const child_stdin = b.addExecutable("child_stdin", "child_stdin.zig");
    child_stdin.setBuildMode(mode);
    const child_env = b.addExecutable("child_env", "child_env.zig");
    child_env.setBuildMode(mode);

    const parent = b.addExecutable("parent", "parent.zig");
    parent.setBuildMode(mode);
    const run_cmd = parent.run();
    run_cmd.addArtifactArg(child_stdinpipe);
    run_cmd.addArtifactArg(child_stdin);
    run_cmd.addArtifactArg(child_env);

    const test_step = b.step("test", "Test it");
    test_step.dependOn(&run_cmd.step);
}
