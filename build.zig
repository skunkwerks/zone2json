const std = @import("std");
const bld = std.build;

pub fn build(b: *bld.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const server_exe = b.addExecutable("zone2json-server", "src/main.zig");
    const server_run_cmd = setupExe(b, server_exe, target, mode);
    const server_run_step = b.step("run-server", "Run the RPC server");
    server_run_step.dependOn(&server_run_cmd.step);

    const exe = b.addExecutable("zone2json", "src/cli_tool.zig");
    const run_cmd = setupExe(b, exe, target, mode);
    const run_step = b.step("run", "Run the CLI tool");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = b.addTest("src/test.zig");
    addDependencies(test_cmd);

    test_cmd.setTarget(target);
    test_cmd.setBuildMode(mode);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);
    test_step.dependOn(try compareOutput(b, exe));
}

fn addDependencies(step: *bld.LibExeObjStep) void {
    step.linkLibC();
    step.linkSystemLibrary("rabbitmq");
    step.linkSystemLibrary("ldns");

    step.addPackagePath("zamqp", "../zamqp/src/zamqp.zig");
    step.addPackagePath("zdns", "../zdns/src/zdns.zig");
}

fn setupExe(b: *bld.Builder, exe: *bld.LibExeObjStep, target: std.zig.CrossTarget, mode: std.builtin.Mode) *bld.RunStep {
    addDependencies(exe);

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    return run_cmd;
}

pub fn compareOutput(b: *bld.Builder, exe: *bld.LibExeObjStep) !*bld.Step {
    const dirPath = "test/zones/";
    const testDir = try std.fs.cwd().openDirZ(dirPath, .{ .iterate = true });
    var it = testDir.iterate();

    const step = b.step("compare-output", "Test - Compare output");

    while (try it.next()) |file| {
        if (std.mem.endsWith(u8, file.name, ".zone")) {
            const run = exe.run();
            run.addArg(try std.mem.concat(b.allocator, u8, &[_][]const u8{ dirPath, file.name }));

            const jsonFileName = try std.mem.concat(b.allocator, u8, &[_][]const u8{ file.name[0 .. file.name.len - "zone".len], "json" });
            run.expectStdOutEqual(try testDir.readFileAlloc(b.allocator, jsonFileName, 50 * 1024));
            step.dependOn(&run.step);
        }
    }
    return step;
}
