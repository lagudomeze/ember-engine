//! T-Engine Zig —— 构建脚本
//!
//! 支持跨平台编译：
//!   Linux:   zig build
//!   Windows: zig build -Dtarget=x86_64-windows-gnu
//!   macOS:   zig build -Dtarget=aarch64-macos
//!
//! 使用方法：
//!   zig build                         # Debug 模式
//!   zig build -Doptimize=ReleaseFast  # 发布模式
//!   zig build run                     # 编译并运行
//!   zig build test                    # 运行测试

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // 主模块
    // -----------------------------------------------------------------------
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------------------
    // 主可执行文件
    // -----------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "ember-engine",
        .root_module = main_module,
    });

    // -----------------------------------------------------------------------
    // 平台相关链接配置
    // -----------------------------------------------------------------------
    const target_info = target.result;

    if (target_info.os.tag == .windows) {
        // Windows: 使用项目内置的 SDL2 开发库
        // 如果 deps/win 不存在，请先运行 ./download_deps.sh
        const sdl_root = b.path("deps/win");
        main_module.addIncludePath(sdl_root.path(b, "include/SDL2"));
        main_module.addLibraryPath(sdl_root.path(b, "lib"));

        // Windows 上 SDL2 需要这些系统库
        main_module.linkSystemLibrary("SDL2", .{ .preferred_link_mode = .static });
        main_module.linkSystemLibrary("opengl32", .{});
        main_module.linkSystemLibrary("gdi32", .{});
        main_module.linkSystemLibrary("user32", .{});
        main_module.linkSystemLibrary("shell32", .{});
        main_module.linkSystemLibrary("ole32", .{});
        main_module.linkSystemLibrary("oleaut32", .{});
        main_module.linkSystemLibrary("winmm", .{});
        main_module.linkSystemLibrary("version", .{});
        main_module.linkSystemLibrary("setupapi", .{});
        main_module.linkSystemLibrary("imm32", .{});
    } else if (target_info.os.tag == .macos) {
        // macOS: 使用 Homebrew 或系统提供的 SDL2
        main_module.linkSystemLibrary("SDL2", .{ .preferred_link_mode = .dynamic });
        main_module.linkSystemLibrary("GL", .{});
    } else {
        // Linux: 使用系统 SDL2
        main_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        main_module.linkSystemLibrary("SDL2", .{ .preferred_link_mode = .dynamic });
        main_module.linkSystemLibrary("GL", .{});
    }

    main_module.link_libc = true; // SDL2 的 C ABI 需要 C 运行时

    // -----------------------------------------------------------------------
    // 安装产物
    // -----------------------------------------------------------------------
    b.installArtifact(exe);

    // 如果是 Windows 目标，同时复制 SDL2.dll 到输出目录
    if (target_info.os.tag == .windows) {
        const install_sdl = b.addInstallFile(
            b.path("deps/win/bin/SDL2.dll"),
            "bin/SDL2.dll",
        );
        b.getInstallStep().dependOn(&install_sdl.step);
    }

    // -----------------------------------------------------------------------
    // 运行步骤
    // -----------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "运行 Ember Engine");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------------
    // 测试步骤
    // -----------------------------------------------------------------------
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "运行所有单元测试");
    test_step.dependOn(&run_tests.step);
}
