//! Wasm 运行时插件系统
//!
//! 通过 Wasmtime 运行时加载社区 MOD（.wasm 模块）。
//! Wasm 插件通过共享内存缓冲区与引擎通信，避免频繁的内存拷贝。
//!
//! 安全模型：
//! - Wasm 模块运行在沙箱中，只能通过宿主函数访问引擎数据
//! - 每个 Wasm 实例有独立的资源上限（内存、燃料/执行时间）
//! - 共享内存通过 C ABI 约定的布局进行读写
//!
//! 架构：
//!   引擎 (Zig)  ←→  共享内存缓冲区  ←→  Wasm 插件
//!                   (结构体格式)        (通过 wasm 内存读写)
//!
//! 注意：Wasmtime 的 Zig 绑定需要从 C ABI 封装。
//! 本模块提供高层抽象，实际链接需引入 wasmtime C 库。

const std = @import("std");
const ecs = @import("ecs.zig");

// ============================================================================
// 共享内存通信协议
// ============================================================================

/// 引擎与 Wasm 模块共享的内存布局
/// 通过 wasm 线性内存偏移量访问
pub const SharedMemoryLayout = struct {
    /// 命令缓冲区偏移量
    pub const CMD_BUFFER_OFFSET: usize = 0;
    /// 命令缓冲区大小（字节）
    pub const CMD_BUFFER_SIZE: usize = 4096;
    /// ECS 数据导出区偏移量
    pub const ECS_EXPORT_OFFSET: usize = CMD_BUFFER_SIZE;
    /// ECS 导出区大小
    pub const ECS_EXPORT_SIZE: usize = 65536;
    /// 日志输出区偏移量
    pub const LOG_OFFSET: usize = CMD_BUFFER_SIZE + ECS_EXPORT_SIZE;
    /// 日志区大小
    pub const LOG_SIZE: usize = 1024;
    /// 共享内存总大小（16 页 = 64KB）
    pub const TOTAL_SIZE: usize = 16 * 65536;

    /// 验证共享内存分配是否足够
    pub fn validate() bool {
        return CMD_BUFFER_SIZE + ECS_EXPORT_SIZE + LOG_SIZE <= TOTAL_SIZE;
    }
};

/// 引擎向 Wasm 模块发送的命令
pub const EngineCommand = enum(u32) {
    /// 无命令
    none = 0,
    /// 初始化模块
    init = 1,
    /// 执行一帧逻辑
    update = 2,
    /// 关闭模块
    shutdown = 3,
    /// 查询实体组件
    query_component = 4,
    /// 添加组件到实体
    add_component = 5,
    /// 移除实体组件
    remove_component = 6,
    /// 发射事件
    emit_event = 7,
};

/// Wasm 模块向引擎返回的响应
pub const ModuleResponse = enum(u32) {
    /// 成功
    ok = 0,
    /// 通用错误
    error = 1,
    /// 实体不存在
    entity_not_found = 2,
    /// 组件类型未注册
    component_not_found = 3,
    /// 内存不足
    out_of_memory = 4,
};

// ============================================================================
// Wasm 模块句柄
// ============================================================================

/// Wasm 模块实例 —— 封装一个已加载的 .wasm 模块
pub const WasmModule = struct {
    /// 模块名称
    name: []const u8,
    /// 指向 wasmtime 存储的 opaque 指针
    _store: ?*anyopaque,
    /// 指向 wasmtime 实例的 opaque 指针
    _instance: ?*anyopaque,
    /// 指向 wasmtime 模块的 opaque 指针
    _module: ?*anyopaque,
    /// 共享内存的基地址（来自 wasm 导出内存）
    _shared_memory: ?[*]u8,
    /// 模块是否已初始化
    initialized: bool,

    // Wasmtime C API 函数声明（在链接时由 libwasmtime 提供）
    // 这里仅声明类型，实际实现在链接阶段解析

    /// 创建一个空的 Wasm 模块句柄
    pub fn create(name: []const u8) WasmModule {
        return .{
            .name = name,
            ._store = null,
            ._instance = null,
            ._module = null,
            ._shared_memory = null,
            .initialized = false,
        };
    }

    /// 从文件加载 .wasm 模块
    /// 在实际实现中使用 wasmtime C API:
    ///   wasmtime_store_new, wasmtime_module_new, wasmtime_instance_new
    pub fn load(self: *WasmModule, allocator: std.mem.Allocator, wasm_path: []const u8) !void {
        _ = allocator;
        _ = wasm_path;
        // 实际实现：
        // 1. 读取 .wasm 文件到内存
        // 2. 创建 wasmtime 引擎和存储
        // 3. 编译模块
        // 4. 实例化，提供宿主函数导入
        // 5. 获取导出内存的指针
        // 6. 调用模块的 _initialize 导出函数
        //
        // 伪代码：
        // const engine = wasm_engine_new();
        // const store = wasmtime_store_new(engine, null, null);
        // const wasm_bytes = try readFile(allocator, wasm_path);
        // const module = wasmtime_module_new(engine, wasm_bytes, wasm_bytes.len);
        // const instance = wasmtime_instance_new(store, module, imports, imports_len);
        // const memory = wasmtime_instance_export_memory(instance, "memory");
        // self._shared_memory = wasmtime_memory_data(memory);
        //
        // 注意：完整的 wasmtime C API 绑定需要生成或手写 Zig 绑定，
        // 这超出了本示例的范围。实际项目中使用 zig-wasmtime 包。

        self.initialized = true;
    }

    /// 向 Wasm 模块发送命令并获取响应
    pub fn sendCommand(self: *WasmModule, cmd: EngineCommand, payload: []const u8) !ModuleResponse {
        if (!self.initialized) return error.ModuleNotInitialized;
        if (self._shared_memory == null) return error.NoSharedMemory;

        _ = cmd;
        _ = payload;
        // 实际实现：
        // 1. 将命令写入共享内存的命令区
        // 2. 调用 Wasm 模块的 handle_command 导出函数
        // 3. 从共享内存读取响应
        //
        // const mem = self._shared_memory.?;
        // @memcpy(mem[CMD_BUFFER_OFFSET..CMD_BUFFER_OFFSET + payload.len], payload);
        // callWasmFunction(self._instance, "handle_command");
        // return @enumFromInt(mem[0]);

        return ModuleResponse.ok;
    }

    /// 执行模块的更新逻辑（每帧调用）
    pub fn update(self: *WasmModule) !void {
        _ = try self.sendCommand(.update, &.{});
    }

    /// 关闭模块并释放资源
    pub fn shutdown(self: *WasmModule) void {
        if (self.initialized) {
            // 发送关闭命令
            self.sendCommand(.shutdown, &.{}) catch {};
            self.initialized = false;
        }
        // 释放 wasmtime 资源
        // wasmtime_instance_delete(self._instance);
        // wasmtime_module_delete(self._module);
        // wasmtime_store_delete(self._store);
    }
};

// ============================================================================
// Wasm 插件管理器
// ============================================================================

/// 管理所有已加载的 Wasm 模块
pub const WasmPluginManager = struct {
    allocator: std.mem.Allocator,
    /// 已加载的模块列表
    modules: std.ArrayList(WasmModule) = .empty,
    /// 是否已启用
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator) WasmPluginManager {
        return .{
            .allocator = allocator,
            .enabled = false,
        };
    }

    pub fn deinit(self: *WasmPluginManager) void {
        for (self.modules.items) |*mod| {
            mod.shutdown();
        }
        self.modules.deinit(self.allocator);
    }

    /// 从目录加载所有 .wasm 模块
    pub fn loadFromDirectory(self: *WasmPluginManager, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            const mod_name = try self.allocator.dupe(u8, entry.name);
            var wasm_mod = WasmModule.create(mod_name);
            wasm_mod.load(self.allocator, full_path) catch |err| {
                std.debug.print("[WasmManager] 加载模块 {s} 失败: {}\n", .{ entry.name, err });
                self.allocator.free(mod_name);
                continue;
            };
            try self.modules.append(self.allocator, wasm_mod);
            std.debug.print("[WasmManager] 已加载模块: {s}\n", .{entry.name});
        }
    }

    /// 更新所有 Wasm 模块（每帧调用）
    pub fn updateAll(self: *WasmPluginManager) void {
        if (!self.enabled) return;
        for (self.modules.items) |*mod| {
            mod.update() catch |err| {
                std.debug.print("[WasmManager] 模块 {s} 更新失败: {}\n", .{ mod.name, err });
            };
        }
    }
};

// ============================================================================
// 宿主函数接口 —— 引擎暴露给 Wasm 模块的函数
// ============================================================================

/// Wasm 模块可调用的宿主函数签名
/// 这些函数通过 C ABI 导出给 Wasm 运行时

/// 在共享内存中写入日志信息
pub fn hostLog(shared_mem: [*]u8, msg_ptr: u32, msg_len: u32) void {
    if (msg_len > SharedMemoryLayout.LOG_SIZE) return;
    const dest = shared_mem[SharedMemoryLayout.LOG_OFFSET..][0..msg_len];
    const src = shared_mem[msg_ptr..][0..msg_len];
    @memcpy(dest, src);
    // 在宿主端打印日志
    std.debug.print("[Wasm:{s}]\n", .{dest});
}

/// 获取引擎的游戏时钟值
pub fn hostGetTick(world: *ecs.World) u64 {
    return world.tick;
}

/// 向世界发射事件（从 Wasm 模块发起）
pub fn hostEmitEvent(world: *ecs.World, event_type: u16, data_ptr: [*]u8, data_len: u32) void {
    _ = world;
    _ = event_type;
    _ = data_ptr;
    _ = data_len;
    // 实际实现：将原始字节反序列化为事件数据并放入世界的事件队列
}
