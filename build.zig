//! T-Engine Zig —— 构建脚本
//!
//! 此构建脚本负责：
//! 1. 编译主游戏可执行文件
//! 2. 链接系统依赖（SDL2、OpenGL）
//! 3. 支持交叉编译和优化配置
//!
//! 使用方法：
//!   zig build           # 编译（Debug 模式）
//!   zig build -Doptimize=ReleaseFast  # 编译（发布模式）
//!   zig build run       # 编译并运行
//!   zig build test      # 运行所有测试
//!
//! 系统依赖要求：
//!   - SDL2 开发库（libsdl2-dev / SDL2-devel）
//!   - OpenGL（通常随显卡驱动提供）
//!   - Zig 0.16.0 或更高版本

const std = @import("std");

pub fn build(b: *std.Build) void {
    // -----------------------------------------------------------------------
    // 构建目标与优化选项
    // -----------------------------------------------------------------------
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // 主模块：创建编译根模块
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
        .name = "t-engine-zig",
        .root_module = main_module,
    });

    // -----------------------------------------------------------------------
    // 链接系统库（在 Zig 0.16 中，链接在 Module 上配置）
    // -----------------------------------------------------------------------
    main_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    main_module.linkSystemLibrary("SDL2", .{ .preferred_link_mode = .dynamic });
    main_module.linkSystemLibrary("GL", .{ .preferred_link_mode = .dynamic });
    main_module.link_libc = true;

    // Wasmtime（可选）—— 取消注释以启用 Wasm 插件支持：
    // exe.linkSystemLibrary("wasmtime");

    // -----------------------------------------------------------------------
    // 安装产物
    // -----------------------------------------------------------------------
    b.installArtifact(exe);

    // -----------------------------------------------------------------------
    // 运行步骤
    // -----------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "运行 T-Engine Zig");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------------
    // 测试步骤：测试 ECS 核心模块
    // -----------------------------------------------------------------------
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/engine/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "运行 ECS 核心测试");
    test_step.dependOn(&run_tests.step);

    // -----------------------------------------------------------------------
    // Wasm 模块构建（可选）
    // -----------------------------------------------------------------------
    // 如需构建 wasm_mod_template.zig 为 .wasm 文件：
    // const wasm_module = b.createModule(.{
    //     .root_source_file = b.path("wasm_mod_template.zig"),
    //     .target = b.resolveTargetQuery(.{
    //         .cpu_arch = .wasm32,
    //         .os_tag = .freestanding,
    //     }),
    //     .optimize = optimize,
    // });
    // const wasm_lib = b.addExecutable(.{
    //     .name = "example_mod",
    //     .root_module = wasm_module,
    // });
    // wasm_lib.rdynamic = true;
    // const wasm_step = b.step("wasm", "构建 Wasm 模块示例");
    // wasm_step.dependOn(&b.addInstallArtifact(wasm_lib).step);
}
