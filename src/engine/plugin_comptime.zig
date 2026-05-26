//! 编译时插件融合系统
//!
//! 设计理念：
//! 所有核心插件的 manifest 在编译期被收集，生成零开销的静态函数调度表。
//! 无需动态加载、无需虚表、无需字符串查找 —— 所有分发在编译期完成。
//!
//! 架构：
//! 1. 每个插件文件导出 `pub const manifest: PluginManifest`
//! 2. `collectPlugins()` 通过 @import 收集所有 manifest
//! 3. 生成静态的 SystemTable 和 ComponentRegistry
//!
//! 使用示例：
//!   const plugins = comptime collectPlugins(.{@import("plugins/core_firemage")});
//!   const world_type = plugins.buildWorldType();

const std = @import("std");
const ecs = @import("ecs.zig");

// ============================================================================
// 插件清单
// ============================================================================

/// 插件清单 —— 每个编译时插件必须导出一个此类型的常量
pub const PluginManifest = struct {
    /// 插件名称（用于调试和日志）
    name: []const u8,
    /// 插件版本
    version: []const u8,
    /// 此插件提供给世界的组件类型列表
    components: []const ComponentEntry,
    /// 此插件提供的系统列表
    systems: []const SystemEntry,
    /// 此插件声明的事件类型
    events: []const EventEntry,
    /// 初始化回调（在世界创建后调用）
    init_fn: ?*const fn (*ecs.World) anyerror!void = null,
};

/// 组件条目：类型名 + 零大小标记类型（用于编译期类型传递）
pub const ComponentEntry = struct {
    /// 组件名称
    name: []const u8,
    /// 组件大小的字节数（用于分配）
    size: usize,
    /// 组件对齐要求
    alignment: u29,
};

/// 系统条目：系统函数的元数据
pub const SystemEntry = struct {
    /// 系统名称
    name: []const u8,
    /// 系统执行的阶段（用于排序）
    phase: SystemPhase,
    /// 类型擦除的执行函数指针
    execute: *const fn (*ecs.World) anyerror!void,
};

/// 事件条目
pub const EventEntry = struct {
    name: []const u8,
    size: usize,
    alignment: u29,
};

/// 系统执行阶段 —— 决定系统在帧内的执行顺序
pub const SystemPhase = enum(u8) {
    /// 输入处理
    input,
    /// AI 决策
    ai,
    /// 移动和物理
    movement,
    /// 战斗和伤害
    combat,
    /// 状态效果更新
    status_effect,
    /// 渲染（通常一帧最后）
    render,
    /// 清理（销毁过期实体等）
    cleanup,

    /// 返回阶段的排序优先级
    pub fn order(self: SystemPhase) u8 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// 编译期插件收集器
// ============================================================================

/// 从多个插件模块中收集所有清单，生成编译期注册表。
/// 用法：const registry = comptime PluginRegistry.collect(.{
///     @import("plugins/core_firemage"),
///     @import("plugins/core_ai_hostile"),
/// });
pub const PluginRegistry = struct {
    manifests: []const PluginManifest,

    /// 收集所有插件清单（comptime 参数确保编译期求值）
    pub fn collect(comptime plugins: anytype) PluginRegistry {
        const num_plugins = @typeInfo(@TypeOf(plugins)).@"struct".fields.len;
        var manifests: [num_plugins]PluginManifest = undefined;
        inline for (plugins, 0..) |plugin, i| {
            manifests[i] = plugin.manifest;
        }
        return PluginRegistry{ .manifests = &manifests };
    }

    /// 收集所有插件声明的组件条目总数
    pub fn totalComponents(self: PluginRegistry) usize {
        var count: usize = 0;
        for (self.manifests) |m| {
            count += m.components.len;
        }
        return count;
    }

    /// 收集所有插件声明的系统条目总数
    pub fn totalSystems(self: PluginRegistry) usize {
        var count: usize = 0;
        for (self.manifests) |m| {
            count += m.systems.len;
        }
        return count;
    }

    /// 生成按阶段排序的系统执行表 —— 编译期完成排序，运行时零开销
    pub fn buildSystemTable(self: PluginRegistry) SystemTable(self.totalSystems()) {
        const total = self.totalSystems();
        var entries: [total]SystemTableEntry = undefined;
        var idx: usize = 0;

        // 展开所有插件收集系统
        for (self.manifests) |m| {
            for (m.systems) |sys| {
                entries[idx] = .{
                    .name = sys.name,
                    .phase = sys.phase,
                    .execute = sys.execute,
                    .plugin_name = m.name,
                };
                idx += 1;
            }
        }

        // 编译期排序：按阶段优先级
        var i: usize = 1;
        while (i < total) : (i += 1) {
            var j = i;
            while (j > 0 and entries[j].phase.order() < entries[j - 1].phase.order()) : (j -= 1) {
                const tmp = entries[j];
                entries[j] = entries[j - 1];
                entries[j - 1] = tmp;
            }
        }

        return SystemTable(total){ .entries = entries };
    }
};

/// 编译期大小确定的系统调度表 —— 嵌入数组，零间接引用
pub fn SystemTable(comptime num: usize) type {
    return struct {
        entries: [num]SystemTableEntry,

        pub fn executeAll(self: @This(), world: *ecs.World) !void {
            for (&self.entries) |entry| {
                try entry.execute(world);
            }
        }

        pub fn len(_: @This()) usize {
            return num;
        }
    };
}

/// 系统表中的单条记录
pub const SystemTableEntry = struct {
    name: []const u8,
    phase: SystemPhase,
    execute: *const fn (*ecs.World) anyerror!void,
    plugin_name: []const u8,
};

// ============================================================================
// 便捷宏：帮助插件声明自己的清单
// ============================================================================

/// 为系统函数生成包装器，使其能被 SystemTable 调用。
/// 用法：
///   fn mySystem(world: *World) !void { ... }
///   pub const manifest = PluginManifest{
///       ...
///       .systems = &.{
///           systemEntry("我的系统", .movement, mySystem),
///       },
///   };
pub fn systemEntry(comptime name: []const u8, comptime phase: SystemPhase, comptime func: anytype) SystemEntry {
    return .{
        .name = name,
        .phase = phase,
        .execute = struct {
            fn execute(world: *ecs.World) !void {
                try @call(.auto, func, .{world});
            }
        }.execute,
    };
}

/// 声明一个组件条目
pub fn componentEntry(comptime name: []const u8, comptime T: type) ComponentEntry {
    return .{
        .name = name,
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
    };
}

/// 声明一个事件条目
pub fn eventEntry(comptime name: []const u8, comptime T: type) EventEntry {
    return .{
        .name = name,
        .size = @sizeOf(T),
        .alignment = @alignOf(T),
    };
}
