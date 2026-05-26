//! 编译时插件：资源系统
//!
//! 提供多种角色资源（法力、耐力、正能量、负能量等）的管理和自然恢复。
//! 对应原 ToME4 的 ActorResource 模块。
//!
//! 组件：
//! - ResourcePool: 单个资源池（当前值/最大值/每回合恢复量）
//!
//! 系统：
//! - resourceRegenSystem: 每回合自动恢复资源

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");

const firemage = @import("core_class_firemage.zig");
const stats_mod = @import("core_stats.zig");

// ============================================================================
// 组件类型 ID
// ============================================================================

pub const COMP_RESOURCE_POOL: u16 = 11;

// ============================================================================
// 资源类型
// ============================================================================

/// 资源种类 —— 对应 ToME4 data/resources.lua
pub const ResourceKind = enum(u8) {
    life = 0, // 生命（由 Health 组件管理，此处保留用于统一接口）
    mana = 1, // 法力
    stamina = 2, // 耐力
    equilibrium = 3, // 失衡（数值越高越危险）
    vim = 4, // 活力（生命窃取资源）
    positive = 5, // 正能量
    negative = 6, // 负能量
    paradox = 7, // 悖论（时空魔法资源）
    psi = 8, // 精神力
    hate = 9, // 仇恨
    souls = 10, // 灵魂
    steam = 11, // 蒸汽（蒸汽科技）

    pub fn nameCN(self: ResourceKind) []const u8 {
        return switch (self) {
            .life => "生命",
            .mana => "法力",
            .stamina => "耐力",
            .equilibrium => "失衡",
            .vim => "活力",
            .positive => "正能量",
            .negative => "负能量",
            .paradox => "悖论",
            .psi => "精神力",
            .hate => "仇恨",
            .souls => "灵魂",
            .steam => "蒸汽",
        };
    }

    /// 每回合自然恢复的基础值
    pub fn baseRegen(self: ResourceKind) f64 {
        return switch (self) {
            .life => 0.5, // 生命缓慢恢复
            .mana => 0.5, // 法力缓慢恢复
            .stamina => 1.0, // 耐力较快恢复
            .equilibrium => 0.1, // 失衡极慢消退
            .vim => 0.0, // 活力不自然恢复
            .positive => 0.3,
            .negative => 0.3,
            .paradox => 0.01, // 悖论几乎不消退
            .psi => 1.0, // 精神力较快恢复
            .hate => -0.5, // 仇恨会衰减
            .souls => 0.0, // 灵魂不自然恢复
            .steam => 0.0, // 蒸汽不自然恢复
        };
    }
};

// ============================================================================
// 组件定义
// ============================================================================

/// 资源池组件 —— 一个实体可以有多个 ResourcePool（不同种类）
/// 注意：生命值由 Health 组件管理，不属于 ResourcePool
pub const ResourcePool = struct {
    kind: ResourceKind,
    current: f64,
    max: f64,
    /// 每回合恢复倍率（1.0 = 正常恢复速度）
    regen_rate: f64 = 1.0,

    /// 消耗资源，成功返回 true
    pub fn consume(self: *ResourcePool, amount: f64) bool {
        if (self.current < amount) return false;
        self.current -= amount;
        return true;
    }

    /// 恢复资源
    pub fn restore(self: *ResourcePool, amount: f64) void {
        self.current = @min(self.max, self.current + amount);
    }

    /// 检查资源是否足够
    pub fn hasEnough(self: *const ResourcePool, amount: f64) bool {
        return self.current >= amount;
    }

    /// 获取当前百分比
    pub fn percent(self: *const ResourcePool) f64 {
        if (self.max <= 0) return 0;
        return (self.current / self.max) * 100.0;
    }

    /// 资源是否耗尽
    pub fn isEmpty(self: *const ResourcePool) bool {
        return self.current <= 0;
    }
};

// ============================================================================
// 系统：资源恢复
// ============================================================================

/// 资源恢复系统 —— 每帧对所有 ResourcePool 执行自然恢复
pub fn resourceRegenSystem(world: *ecs.World) !void {
    const storage = world.typedStorage(ResourcePool, COMP_RESOURCE_POOL);
    var iter = storage.iter();
    while (iter.next()) |row| {
        const base = row.component.kind.baseRegen();
        const regen = base * row.component.regen_rate;

        if (regen > 0) {
            row.component.restore(regen);
        } else if (regen < 0) {
            // 衰减（如仇恨）：确保不低于 0
            row.component.current = @max(0, row.component.current + regen);
        }
    }
}

// ============================================================================
// 辅助函数
// ============================================================================

/// 为实体添加资源池
pub fn addResourceToEntity(
    world: *ecs.World,
    entity: ecs.Entity,
    kind: ResourceKind,
    max_value: f64,
) !void {
    try world.addComponent(entity, ResourcePool, COMP_RESOURCE_POOL, .{
        .kind = kind,
        .current = max_value,
        .max = max_value,
    });
}

/// 查找实体的特定资源池
pub fn findResource(world: *ecs.World, entity: ecs.Entity, kind: ResourceKind) ?*ResourcePool {
    const storage = world.typedStorage(ResourcePool, COMP_RESOURCE_POOL);
    var iter = storage.iter();
    while (iter.next()) |row| {
        if (row.entity.eql(entity) and row.component.kind == kind) {
            return row.component;
        }
    }
    return null;
}

// ============================================================================
// 插件清单
// ============================================================================

pub const manifest = plugin.PluginManifest{
    .name = "资源系统",
    .version = "1.0.0",
    .components = &.{
        plugin.componentEntry("ResourcePool", ResourcePool),
    },
    .systems = &.{
        plugin.systemEntry("资源恢复", .status_effect, resourceRegenSystem),
    },
    .events = &.{},
};
