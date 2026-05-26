//! 编译时插件：天赋与技能系统
//!
//! 对应原 ToME4 ActorTalents、ActorTemporaryEffects 模块。
//! 设计理念：
//! - 天赋是纯数据模板，在编译期定义
//! - 三种模式：Active（主动施放）、Sustain（持续维持）、Passive（被动生效）
//! - 冷却和资源消耗通过 ECS 组件管理
//!
//! 组件：
//! - TalentData: 已学习天赋（等级、冷却剩余）
//! - Cooldown: 冷却状态（每 tick 递减）

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");
const rng_mod = @import("../engine/rng.zig");

const firemage = @import("core_class_firemage.zig");
const stats_mod = @import("core_stats.zig");
const resources_mod = @import("core_resources.zig");

// ============================================================================
// 组件类型 ID（从 12 开始）
// ============================================================================

pub const COMP_TALENTS: u16 = 12; // 已学习天赋的集合
pub const COMP_COOLDOWNS: u16 = 13; // 冷却计时器集合

pub const EVENT_TALENT_USED: u16 = 4;

// ============================================================================
// 天赋模式
// ============================================================================

pub const TalentMode = enum(u8) {
    active, // 主动施放：消耗资源 + 触发冷却 + 立即产生效果
    sustain, // 持续维持：持续消耗资源上限，提供持续效果
    passive, // 被动：始终生效，无条件
};

// ============================================================================
// 天赋模板 —— 编译期定义
// ============================================================================

pub const TalentDef = struct {
    name: []const u8, // 天赋名称（中文）
    mode: TalentMode, // 天赋模式
    cooldown: u32, // 冷却回合数（0=无冷却）
    mana_cost: f64, // 法力消耗（0=无消耗）
    stamina_cost: f64, // 耐力消耗
    damage_mult: f64, // 伤害倍率（每等级提升）
    damage_type: stats_mod.DamageType, // 造成的伤害类型
    base_damage: i32, // 基础伤害值
    range: u32, // 施放距离（0=自身/近战）
    description: []const u8, // 描述文本

    /// 计算给定等级下的实际伤害
    pub fn calcDamage(self: TalentDef, level: u32, spell_power: i32) i32 {
        const base: f64 = @floatFromInt(self.base_damage);
        const mult: f64 = self.damage_mult;
        const lvl: f64 = @floatFromInt(level);
        // 伤害 = (基础 + 等级*倍率*基础) + 法术强度*0.5
        const raw = base + base * mult * lvl * 0.3 + @as(f64, @floatFromInt(spell_power)) * 0.5;
        return @intFromFloat(@max(1.0, raw));
    }
};

// ============================================================================
// 预定义天赋 —— 火法师
// ============================================================================

/// 天赋数据库（编译期定义，扩展时在这里添加新天赋）
pub const talent_db = [_]TalentDef{
    .{
        .name = "火球术",
        .mode = .active,
        .cooldown = 3,
        .mana_cost = 15,
        .stamina_cost = 0,
        .damage_mult = 1.5,
        .damage_type = .fire,
        .base_damage = 25,
        .range = 8,
        .description = "向目标方向发射一个火球，对命中的敌人造成火焰伤害，并附加灼烧效果。",
    },
    .{
        .name = "烈焰风暴",
        .mode = .active,
        .cooldown = 6,
        .mana_cost = 30,
        .stamina_cost = 0,
        .damage_mult = 2.0,
        .damage_type = .fire,
        .base_damage = 40,
        .range = 5,
        .description = "在目标区域召唤烈焰风暴，对所有范围内的敌人造成大量火焰伤害。",
    },
    .{
        .name = "火焰护盾",
        .mode = .sustain,
        .cooldown = 12,
        .mana_cost = 50,
        .stamina_cost = 0,
        .damage_mult = 0.5,
        .damage_type = .fire,
        .base_damage = 10,
        .range = 0,
        .description = "召唤火焰护盾保护自身，持续期间对攻击者造成火焰反击伤害。",
    },
    .{
        .name = "元素掌握",
        .mode = .passive,
        .cooldown = 0,
        .mana_cost = 0,
        .stamina_cost = 0,
        .damage_mult = 0.3,
        .damage_type = .fire,
        .base_damage = 0,
        .range = 0,
        .description = "你对火焰魔法的理解更加深入，所有火焰伤害提升。",
    },
};

// ============================================================================
// 组件定义
// ============================================================================

/// 已学习天赋 —— 记录实体知道的天赋及等级
pub const LearnedTalent = struct {
    talent_id: u8, // talent_db 中的索引
    level: u32, // 当前等级（1-5）
};

/// 冷却追踪
pub const CooldownEntry = struct {
    talent_id: u8,
    remaining: u32, // 剩余冷却回合数
};

/// 天赋集合组件
pub const TalentComponent = struct {
    learned: std.ArrayList(LearnedTalent) = .empty,
    cooldowns: std.ArrayList(CooldownEntry) = .empty,
};

// ============================================================================
// 事件
// ============================================================================

pub const TalentUsedEvent = struct {
    caster: ecs.Entity,
    talent_id: u8,
    talent_name: []const u8,
    level: u32,
    target_x: i32,
    target_y: i32,

    pub const event_type_id = EVENT_TALENT_USED;
};

// ============================================================================
// 系统：冷却管理
// ============================================================================

/// 冷却推进系统 —— 每 tick 减少所有冷却的 remaining
pub fn cooldownTickSystem(world: *ecs.World) !void {
    const storage = world.typedStorage(TalentComponent, COMP_TALENTS);
    var iter = storage.iter();
    while (iter.next()) |row| {
        var i: usize = 0;
        while (i < row.component.cooldowns.items.len) {
            row.component.cooldowns.items[i].remaining -= 1;
            if (row.component.cooldowns.items[i].remaining == 0) {
                // 冷却完成，移除
                _ = row.component.cooldowns.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

// ============================================================================
// 天赋操作函数
// ============================================================================

/// 获取实体某个天赋的等级（0=未学会）
pub fn getTalentLevel(world: *ecs.World, entity: ecs.Entity, talent_id: u8) u32 {
    if (world.getComponent(entity, TalentComponent, COMP_TALENTS)) |talents| {
        for (talents.learned.items) |t| {
            if (t.talent_id == talent_id) return t.level;
        }
    }
    return 0;
}

/// 学会天赋
pub fn learnTalent(world: *ecs.World, entity: ecs.Entity, talent_id: u8, level: u32) !void {
    if (talent_id >= talent_db.len) return;

    if (world.getComponent(entity, TalentComponent, COMP_TALENTS)) |talents| {
        // 检查是否已学会
        for (talents.learned.items) |*t| {
            if (t.talent_id == talent_id) {
                t.level = @min(5, t.level + level);
                return;
            }
        }
        // 新学
        try talents.learned.append(world.allocator, .{ .talent_id = talent_id, .level = level });
    }
}

/// 检查天赋是否在冷却
pub fn isOnCooldown(world: *ecs.World, entity: ecs.Entity, talent_id: u8) bool {
    if (world.getComponent(entity, TalentComponent, COMP_TALENTS)) |talents| {
        for (talents.cooldowns.items) |cd| {
            if (cd.talent_id == talent_id) return true;
        }
    }
    return false;
}

/// 获取剩余冷却回合数
pub fn getCooldownRemaining(world: *ecs.World, entity: ecs.Entity, talent_id: u8) u32 {
    if (world.getComponent(entity, TalentComponent, COMP_TALENTS)) |talents| {
        for (talents.cooldowns.items) |cd| {
            if (cd.talent_id == talent_id) return cd.remaining;
        }
    }
    return 0;
}

/// 使用天赋 —— 返回 true 表示施放成功
pub fn useTalent(
    world: *ecs.World,
    caster: ecs.Entity,
    talent_id: u8,
    target_x: i32,
    target_y: i32,
    rng: *rng_mod.RNG,
) !bool {
    if (talent_id >= talent_db.len) return false;
    const talent = talent_db[talent_id];

    // 检查冷却
    if (isOnCooldown(world, caster, talent_id)) return false;

    const level = getTalentLevel(world, caster, talent_id);
    if (level == 0 and talent.mode != .passive) return false; // 未学会

    const effective_level = if (level == 0) @as(u32, 1) else level;

    // 获取施法者属性
    var spell_power: i32 = 10;
    if (world.getComponent(caster, stats_mod.Stats, stats_mod.COMP_STATS)) |stats| {
        spell_power = stats.spell_power;
    }

    // 技能不消耗 resources_mod 中的资源，这里改用 Mana 组件
    // 法力消耗检查（使用 firemage 的 Mana 组件）
    if (talent.mana_cost > 0) {
        if (world.getComponent(caster, firemage.Mana, firemage.COMP_MANA)) |mana| {
            const cost: i32 = @intFromFloat(talent.mana_cost);
            if (mana.current < cost) return false;
            mana.current -= cost;
        }
    }

    // 计算伤害
    const damage = talent.calcDamage(effective_level, spell_power);

    // 对目标造成伤害
    const pos_storage = world.typedStorage(firemage.Position, firemage.COMP_POSITION);
    var pos_iter = pos_storage.iter();
    while (pos_iter.next()) |row| {
        // 跳过施法者自身
        if (row.entity.eql(caster)) continue;

        if (row.component.x == target_x and row.component.y == target_y) {
            // 检查目标是否有生命
            if (world.getComponent(row.entity, firemage.Health, firemage.COMP_HEALTH)) |health| {
                // 实际伤害计算（考虑抗性等）
                const actual_dmg = stats_mod.calculateDamage(
                    damage, talent.damage_type,
                    world.getComponent(caster, stats_mod.Stats, stats_mod.COMP_STATS),
                    world.getComponent(row.entity, stats_mod.Stats, stats_mod.COMP_STATS),
                    world.getComponent(row.entity, stats_mod.CombatStats, stats_mod.COMP_COMBAT_STATS),
                    rng,
                );

                health.takeDamage(actual_dmg);

                // 发射伤害事件
                try world.emit(stats_mod.DamageEvent, .{
                    .target = row.entity,
                    .source = caster,
                    .amount = actual_dmg,
                    .damage_type = talent.damage_type,
                });

                // 火焰伤害附加灼烧
                if (talent.damage_type == .fire and actual_dmg > 5) {
                    const burn_dmg = @max(1, @divTrunc(actual_dmg, 3));
                    // 检查目标是否已有灼烧
                    if (world.getComponent(row.entity, firemage.Burning, firemage.COMP_BURNING)) |burn| {
                        burn.remaining_ticks += 2;
                        burn.damage_per_tick = @max(burn.damage_per_tick, burn_dmg);
                    } else {
                        try world.addComponent(row.entity, firemage.Burning, firemage.COMP_BURNING, .{
                            .damage_per_tick = burn_dmg,
                            .remaining_ticks = 3,
                        });
                    }
                }
            }
            break;
        }
    }

    // 添加冷却
    if (talent.cooldown > 0) {
        if (world.getComponent(caster, TalentComponent, COMP_TALENTS)) |talents| {
            try talents.cooldowns.append(world.allocator, .{
                .talent_id = talent_id,
                .remaining = talent.cooldown,
            });
        }
    }

    // 发射天赋使用事件
    try world.emit(TalentUsedEvent, .{
        .caster = caster,
        .talent_id = talent_id,
        .talent_name = talent.name,
        .level = effective_level,
        .target_x = target_x,
        .target_y = target_y,
    });

    return true;
}

// ============================================================================
// 插件清单
// ============================================================================

pub const manifest = plugin.PluginManifest{
    .name = "天赋系统",
    .version = "1.0.0",
    .components = &.{
        plugin.componentEntry("TalentComponent", TalentComponent),
    },
    .systems = &.{
        plugin.systemEntry("冷却管理", .status_effect, cooldownTickSystem),
    },
    .events = &.{
        plugin.eventEntry("TalentUsedEvent", TalentUsedEvent),
    },
};
