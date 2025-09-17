const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false, // disable TLS for now
    });
    // const zexplorer = b.dependency("zexplorer", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // const exe = b.addExecutable(.{
    //     .name = "htmz",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "htmz", .module = mod },
    //         },
    //     }),
    // });

    // exe.root_module.addImport("sqlite", sqlite.module("sqlite"));

    // b.installArtifact(exe);

    // Add JWT executable
    const jwt_exe = b.addExecutable(.{
        .name = "htmz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_jwt_clean.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    jwt_exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    jwt_exe.root_module.addImport("zap", zap.module("zap"));
    // jwt_exe.root_module.addImport("zexplorer", zexplorer.module("zexplorer"));

    b.installArtifact(jwt_exe);

    // Add JWT run step
    const run_jwt_step = b.step("run", "Run the JWT app");
    const run_jwt_cmd = b.addRunArtifact(jwt_exe);
    run_jwt_step.dependOn(&run_jwt_cmd.step);
    run_jwt_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_jwt_cmd.addArgs(args);
    }
}
