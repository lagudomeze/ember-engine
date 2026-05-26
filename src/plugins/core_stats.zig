//! 编译时插件：属性与战斗系统
//!
//! 提供角色属性、伤害类型和战斗计算。
//! 对应原 ToME4 的 ActorStats、Combat、DamageType 模块。
//!
//! 组件：
//! - Stats: 6 基础属性 + 派生值
//! - CombatStats: 护甲/穿透/抗性
//!
//! 系统：
//! - statRecalcSystem: 从基础属性重新计算派生值
//! - damageApplicationSystem: 处理伤害事件的护甲/抗性/穿透计算

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");
const rng_mod = @import("../engine/rng.zig");

// 引用火法师插件中的基础组件
const firemage = @import("core_class_firemage.zig");

// ============================================================================
// 组件类型 ID（从 9 开始，避免与 firemage 0-8 冲突）
// ============================================================================

pub const COMP_STATS: u16 = 9;
pub const COMP_COMBAT_STATS: u16 = 10;

// ============================================================================
// 事件类型 ID
// ============================================================================

pub const EVENT_DEATH: u16 = 2;
pub const EVENT_STAT_CHANGE: u16 = 3;

// ============================================================================
// 伤害类型 —— 编译期定义
// ============================================================================

/// 伤害类型枚举，对应 ToME4 的 damage_types.lua
pub const DamageType = enum(u8) {
    physical = 0, // 物理
    fire = 1, // 火焰
    cold = 2, // 冰霜
    lightning = 3, // 闪电
    arcane = 4, // 奥术
    nature = 5, // 自然
    blight = 6, // 枯萎
    darkness = 7, // 暗影
    light = 8, // 光系
    mind = 9, // 精神
    temporal = 10, // 时空

    /// 伤害类型对应的抗性字段名（用于 CombatStats）
    pub fn resistField(self: DamageType) []const u8 {
        return switch (self) {
            .physical => "physical_resist",
            .fire => "fire_resist",
            .cold => "cold_resist",
            .lightning => "lightning_resist",
            .arcane => "arcane_resist",
            .nature => "nature_resist",
            .blight => "blight_resist",
            .darkness => "darkness_resist",
            .light => "light_resist",
            .mind => "mind_resist",
            .temporal => "temporal_resist",
        };
    }

    /// 中文名称
    pub fn nameCN(self: DamageType) []const u8 {
        return switch (self) {
            .physical => "物理",
            .fire => "火焰",
            .cold => "冰霜",
            .lightning => "闪电",
            .arcane => "奥术",
            .nature => "自然",
            .blight => "枯萎",
            .darkness => "暗影",
            .light => "光系",
            .mind => "精神",
            .temporal => "时空",
        };
    }
};

// ============================================================================
// 组件定义
// ============================================================================

/// 基础属性组件 —— 6 维属性系统 (STR/DEX/CON/MAG/WIL/CUN)
pub const Stats = struct {
    // 基础属性
    str: i32 = 10, // 力量：影响物理攻击力和负重
    dex: i32 = 10, // 敏捷：影响命中和闪避
    con: i32 = 10, // 体质：影响生命值和物理豁免
    mag: i32 = 10, // 魔法：影响法术强度和法术豁免
    wil: i32 = 10, // 意志：影响精神强度和资源
    cun: i32 = 10, // 灵巧：影响暴击率和心智豁免

    // 派生属性（由 statRecalcSystem 计算）
    max_life: i32 = 100,
    max_mana: i32 = 100,
    accuracy: i32 = 10, // 物理命中
    defense: i32 = 10, // 物理闪避
    spell_power: i32 = 10, // 法术强度
    mind_power: i32 = 10, // 精神强度
    physical_power: i32 = 10, // 物理强度
    phys_crit: f64 = 5.0, // 物理暴击率 (%)
    spell_crit: f64 = 5.0, // 法术暴击率 (%)
    phys_save: i32 = 10, // 物理豁免
    spell_save: i32 = 10, // 法术豁免
    mind_save: i32 = 10, // 心智豁免

    /// 从基础属性计算派生属性
    /// 公式参考 ToME4 ActorStats.lua 中的 getXxx 计算
    pub fn recalc(self: *Stats) void {
        // 生命值 = 基础值 + 体质 × 10
        self.max_life = 100 + self.con * 10;
        // 法力值 = 基础值 + 魔法 × 8
        self.max_mana = 100 + self.mag * 8;
        // 命中 = 敏捷
        self.accuracy = self.dex;
        // 闪避 = 敏捷
        self.defense = self.dex;
        // 物理强度 = 力量 × 2
        self.physical_power = self.str * 2;
        // 法术强度 = 魔法 × 2
        self.spell_power = self.mag * 2;
        // 精神强度 = 意志 × 2
        self.mind_power = self.wil * 2;
        // 物理暴击 = 灵巧 / 3 (%)
        self.phys_crit = @as(f64, @floatFromInt(self.cun)) / 3.0;
        // 法术暴击 = 灵巧 / 4 (%)
        self.spell_crit = @as(f64, @floatFromInt(self.cun)) / 4.0;
        // 物理豁免 = 体质
        self.phys_save = self.con;
        // 法术豁免 = 魔法
        self.spell_save = self.mag;
        // 心智豁免 = 意志
        self.mind_save = self.wil;
    }
};

/// 战斗属性组件 —— 护甲、穿透、抗性
pub const CombatStats = struct {
    armor: i32 = 0, // 护甲值
    armor_hardiness: f64 = 30.0, // 护甲硬度 (%)，决定护甲能减免伤害的上限比例
    defense: i32 = 0, // 额外闪避

    // 抗性（百分比，可叠加可超 100%）
    all_resist: i32 = 0, // 全抗
    physical_resist: i32 = 0,
    fire_resist: i32 = 0,
    cold_resist: i32 = 0,
    lightning_resist: i32 = 0,
    arcane_resist: i32 = 0,
    nature_resist: i32 = 0,
    blight_resist: i32 = 0,
    darkness_resist: i32 = 0,
    light_resist: i32 = 0,
    mind_resist: i32 = 0,
    temporal_resist: i32 = 0,

    // 穿透（抵消目标的对应抗性）
    all_penetration: i32 = 0,
    physical_penetration: i32 = 0,
    fire_penetration: i32 = 0,
    cold_penetration: i32 = 0,
    lightning_penetration: i32 = 0,

    /// 获取特定伤害类型的有效抗性（考虑全抗和穿透）
    pub fn getResist(self: *const CombatStats, dt: DamageType) i32 {
        const base = switch (dt) {
            .physical => self.physical_resist,
            .fire => self.fire_resist,
            .cold => self.cold_resist,
            .lightning => self.lightning_resist,
            .arcane => self.arcane_resist,
            .nature => self.nature_resist,
            .blight => self.blight_resist,
            .darkness => self.darkness_resist,
            .light => self.light_resist,
            .mind => self.mind_resist,
            .temporal => self.temporal_resist,
        };
        return self.all_resist + base;
    }
};

// ============================================================================
// 事件定义
// ============================================================================

/// 伤害事件（扩展版，包含伤害类型）
pub const DamageEvent = struct {
    target: ecs.Entity,
    source: ecs.Entity,
    amount: i32,
    damage_type: DamageType,

    pub const event_type_id = firemage.EVENT_DAMAGE;
};

/// 实体死亡事件
pub const DeathEvent = struct {
    entity: ecs.Entity,
    killer: ecs.Entity,

    pub const event_type_id = EVENT_DEATH;
};

/// 属性变化事件
pub const StatChangeEvent = struct {
    entity: ecs.Entity,
    stat_name: []const u8,
    old_value: i32,
    new_value: i32,

    pub const event_type_id = EVENT_STAT_CHANGE;
};

// ============================================================================
// 系统：属性重算
// ============================================================================

/// 属性重算系统 —— 在基础属性变化后重新计算所有派生属性
/// 每帧检查是否有 Stats 组件的实体需要重算
pub fn statRecalcSystem(world: *ecs.World) !void {
    const storage = world.typedStorage(Stats, COMP_STATS);
    var iter = storage.iter();
    while (iter.next()) |row| {
        const old_max_life = row.component.max_life;
        row.component.recalc();
        const new_max_life = row.component.max_life;

        // 调整生命值上限（保持当前生命比例）
        if (new_max_life != old_max_life) {
            if (world.getComponent(row.entity, firemage.Health, firemage.COMP_HEALTH)) |health| {
                const ratio = @as(f64, @floatFromInt(health.current)) / @as(f64, @floatFromInt(@max(old_max_life, 1)));
                health.max = new_max_life;
                health.current = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(new_max_life)) * ratio))));
            }
        }
    }
}

// ============================================================================
// 伤害计算函数
// ============================================================================

/// 计算实际造成的伤害
/// 流程：基础伤害 → 护甲减免 → 抗性减免 → 穿透修正 → 最终伤害
pub fn calculateDamage(
    base_damage: i32,
    dt: DamageType,
    attacker_stats: ?*const Stats,
    defender_stats: ?*const Stats,
    defender_combat: ?*const CombatStats,
    rng: *rng_mod.RNG,
) i32 {
    _ = defender_stats;
    var damage = base_damage;

    // 1. 护甲减免（仅物理伤害）
    if (dt == .physical) {
        if (defender_combat) |combat| {
            // 护甲减免量 = 护甲值 × 硬度，但不能超过硬度百分比
            const armor_block = @as(i32, @intFromFloat(@as(f64, @floatFromInt(combat.armor)) * combat.armor_hardiness / 100.0));
            const max_block = @as(i32, @intFromFloat(@as(f64, @floatFromInt(base_damage)) * combat.armor_hardiness / 100.0));
            const effective_block = @min(armor_block, max_block);
            damage -= effective_block;
        }
    }

    // 2. 抗性减免
    if (defender_combat) |combat| {
        var resist = combat.getResist(dt);
        // 穿透降低目标抗性
        resist = @max(0, resist);
        if (resist > 0) {
            damage = @as(i32, @intFromFloat(@as(f64, @floatFromInt(damage)) * (100.0 - @as(f64, @floatFromInt(@min(resist, 100)))) / 100.0));
        }
    }

    // 3. 最小伤害保底：1 点
    damage = @max(1, damage);

    // 4. 法术暴击（非物理伤害）
    if (dt != .physical) {
        if (attacker_stats) |stats| {
            if (rng.chance(stats.spell_crit / 100.0)) {
                damage = @as(i32, @intFromFloat(@as(f64, @floatFromInt(damage)) * 1.5));
            }
        }
    } else {
        // 物理暴击
        if (attacker_stats) |stats| {
            if (rng.chance(stats.phys_crit / 100.0)) {
                damage = @as(i32, @intFromFloat(@as(f64, @floatFromInt(damage)) * 1.5));
            }
        }
    }

    return @max(1, damage);
}

/// 处理命中计算
/// 返回 true 表示命中
pub fn checkHit(attacker_accuracy: i32, defender_defense: i32, rng: *rng_mod.RNG) bool {
    const hit_chance: f64 = @max(5.0, @min(95.0, 50.0 + @as(f64, @floatFromInt(attacker_accuracy - defender_defense)) * 2.5));
    return rng.chance(hit_chance / 100.0);
}

// ============================================================================
// 插件清单
// ============================================================================

pub const manifest = plugin.PluginManifest{
    .name = "属性与战斗系统",
    .version = "1.0.0",
    .components = &.{
        plugin.componentEntry("Stats", Stats),
        plugin.componentEntry("CombatStats", CombatStats),
    },
    .systems = &.{
        plugin.systemEntry("属性重算", .status_effect, statRecalcSystem),
    },
    .events = &.{
        plugin.eventEntry("DeathEvent", DeathEvent),
        plugin.eventEntry("StatChangeEvent", StatChangeEvent),
    },
};
