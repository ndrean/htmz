const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const zap = b.dependency("zap", .{
    //     .target = target,
    //     .optimize = optimize,
    //     .openssl = false, // disable TLS for now
    // });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Frontend asset URL routes (not file paths)
    const frontend_assets = [_][]const u8{
        "/index.css",
        "/htmx.min.js",
        "/ws.min.js",
        "/robots.txt",
        "/favicon.ico",
    };

    // Create build options for frontend assets
    const build_options = b.addOptions();
    build_options.addOption([]const []const u8, "frontend_assets", &frontend_assets);

    const exe = b.addExecutable(.{
        .name = "htmz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    // exe.root_module.addImport("zap", zap.module("zap"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    // Add run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
