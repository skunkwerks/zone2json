const bld = @import("std").build;

fn addDependencies(step: *bld.LibExeObjStep) void {
    step.linkLibC();
    step.linkSystemLibrary("rabbitmq");
    step.linkSystemLibrary("ldns");
}

pub fn build(b: *bld.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zone2json", "src/main.zig");
    exe.addPackagePath("zamqp", "../zamqp/src/zamqp.zig");
    exe.addPackagePath("zdns", "../zdns/src/zdns.zig");

    addDependencies(exe);

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
