//! Wasm 插件模板
//!
//! 此文件展示如何编写一个 Wasm 插件（MOD），通过 C ABI 与 T-Engine 通信。
//!
//! 编译为 .wasm：
//!   zig build-exe wasm_mod_template.zig -target wasm32-freestanding -fno-entry -rdynamic
//!
//! 架构：
//!   Wasm 模块通过共享内存（从宿主导入或导出）与引擎通信。
//!   模块导出以下函数供引擎调用：
//!     - plugin_init(mem: [*]u8, mem_size: u32) -> u32
//!     - plugin_update(mem: [*]u8, mem_size: u32) -> u32
//!     - plugin_shutdown() -> u32
//!     - plugin_manifest_ptr() -> u32 (返回清单在内存中的偏移量)
//!
//! 通信协议：
//!   共享内存布局（由引擎定义）：
//!     [0..4096)      命令缓冲区（引擎写入命令，模块读取）
//!     [4096..69632)   ECS 数据导出区（模块可读写）
//!     [69632..70656)  日志输出区（模块写入日志）
//!
//! 注意：这是一个模板文件，展示结构和协议。
//! 实际的 Wasm 插件需要实现自己的游戏逻辑。

const std = @import("std");

// ============================================================================
// 共享内存布局常量（必须与引擎的 SharedMemoryLayout 一致）
// ============================================================================

const CMD_BUFFER_OFFSET: usize = 0;
const CMD_BUFFER_SIZE: usize = 4096;
const ECS_EXPORT_OFFSET: usize = 4096;
const ECS_EXPORT_SIZE: usize = 65536;
const LOG_OFFSET: usize = CMD_BUFFER_SIZE + ECS_EXPORT_SIZE;
const LOG_SIZE: usize = 1024;

// ============================================================================
// 引擎命令码（必须一致）
// ============================================================================

const EngineCommand = enum(u32) {
    none = 0,
    init = 1,
    update = 2,
    shutdown = 3,
    query_component = 4,
    add_component = 5,
    remove_component = 6,
    emit_event = 7,
};

const ModuleResponse = enum(u32) {
    ok = 0,
    error = 1,
    entity_not_found = 2,
    component_not_found = 3,
    out_of_memory = 4,
};

// ============================================================================
// 插件状态
// ============================================================================

var initialized: bool = false;
var tick_count: u64 = 0;

// ============================================================================
// 导出函数 —— 引擎调用的入口点
// ============================================================================

/// 插件初始化
/// 参数 mem: 共享内存指针
/// 参数 mem_size: 共享内存字节数
/// 返回 ModuleResponse
export fn plugin_init(mem: [*]u8, mem_size: u32) u32 {
    _ = mem_size;
    if (initialized) return @intFromEnum(ModuleResponse.error);

    // 在日志区写入初始化消息
    const log_msg = "Wasm 插件已初始化";
    const log_dst = mem[LOG_OFFSET..][0..LOG_SIZE];
    @memset(log_dst[0..LOG_SIZE], 0);
    @memcpy(log_dst[0..log_msg.len], log_msg);

    initialized = true;
    tick_count = 0;
    return @intFromEnum(ModuleResponse.ok);
}

/// 插件每帧更新
/// 引擎在每帧调用此函数，通过命令缓冲区传递指令
export fn plugin_update(mem: [*]u8, mem_size: u32) u32 {
    _ = mem_size;
    if (!initialized) return @intFromEnum(ModuleResponse.error);

    tick_count += 1;

    // 读取命令缓冲区中的命令
    const cmd_int = std.mem.readInt(u32, mem[CMD_BUFFER_OFFSET..][0..4], .little);
    const cmd: EngineCommand = @enumFromInt(cmd_int);

    switch (cmd) {
        .update => {
            // 执行每帧逻辑
            // 例如：更新 AI 状态、处理技能冷却等
            // 此处为模板占位
        },
        .query_component => {
            // 处理组件查询请求
            // 从命令缓冲区读取参数，查询 ECS 数据，写入响应
        },
        .add_component => {
            // 处理添加组件请求
        },
        else => {},
    }

    return @intFromEnum(ModuleResponse.ok);
}

/// 插件关闭
export fn plugin_shutdown() u32 {
    if (!initialized) return @intFromEnum(ModuleResponse.error);
    initialized = false;
    return @intFromEnum(ModuleResponse.ok);
}

/// 返回插件清单在内存中的偏移量
/// 引擎通过此偏移量读取插件的元数据
export fn plugin_manifest_ptr() u32 {
    // 在实际实现中，manifest 结构体会被序列化到一段内存中
    // 此处返回一个虚构的偏移量
    return ECS_EXPORT_OFFSET;
}

// ============================================================================
// 辅助函数
// ============================================================================

/// 在共享内存的日志区写入文本
fn writeLog(mem: [*]u8, msg: []const u8) void {
    if (msg.len > LOG_SIZE) return;
    const log_dst = mem[LOG_OFFSET..][0..LOG_SIZE];
    @memset(log_dst, 0);
    @memcpy(log_dst[0..msg.len], msg);
}

/// 从共享内存读取 u32（小端序）
fn readU32(mem: [*]u8, offset: usize) u32 {
    return std.mem.readInt(u32, mem[offset..][0..4], .little);
}

/// 向共享内存写入 u32（小端序）
fn writeU32(mem: [*]u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
}

// ============================================================================
// Wasm 内存导出（必须提供至少一页内存供引擎访问）
// ============================================================================

/// 导出线性内存供宿主访问
/// 在实际构建中，可以使用 zig 的 --export-memory 选项导出内存
/// 或者使用 --import-memory 从宿主导入内存
/// 此处声明为 16 页（1MB）
var wasm_memory: [16 * 65536]u8 align(65536) = [_]u8{0} ** (16 * 65536);

// 注意：上面的数组只是用于演示的占位。
// 实际的 Wasm 模块应该导出 WebAssembly.Memory 实例。
// 在 Zig 中编译到 wasm32-freestanding 时，需要使用特殊的链接选项。
