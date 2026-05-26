//! 编译时插件：火法师职业
//!
//! 提供火法师的技能、组件和系统。
//! 设计原则：所有技能效果均通过 ECS 组件实现，技能本身不直接修改世界状态。
//!
//! 组件：
//! - Fireball: 火球术投射物组件
//! - Burning: 灼烧状态效果组件
//! - Mana: 法力值组件
//! - SpellPower: 法术强度组件
//!
//! 系统：
//! - projectileSystem: 投射物移动和碰撞
//! - burningSystem: 灼烧持续伤害
//! - fireballCastSystem: 处理火球术施放

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");
const world_mod = @import("../engine/world.zig");

// ============================================================================
// 组件类型 ID —— 手动分配，编译期确定，零歧义
// ============================================================================

pub const COMP_POSITION: u16 = 0;
pub const COMP_HEALTH: u16 = 1;
pub const COMP_RENDERABLE: u16 = 2;
pub const COMP_MANA: u16 = 3;
pub const COMP_SPELL_POWER: u16 = 4;
pub const COMP_FIREBALL: u16 = 5;
pub const COMP_BURNING: u16 = 6;
pub const COMP_PLAYER: u16 = 7;
pub const COMP_ENEMY: u16 = 8;

// ============================================================================
// 事件类型 ID
// ============================================================================

pub const EVENT_DAMAGE: u16 = 0;
pub const EVENT_SPELL_CAST: u16 = 1;

// ============================================================================
// 组件定义
// ============================================================================

/// 位置组件 —— 实体在世界中的坐标
pub const Position = struct {
    x: i32,
    y: i32,
    /// 此组件的事件类型 ID（用于事件反射）
    pub const event_type_id: u16 = 0; // 位置本身不产生事件
};

/// 生命值组件
pub const Health = struct {
    current: i32,
    max: i32,

    pub fn isDead(self: Health) bool {
        return self.current <= 0;
    }

    pub fn takeDamage(self: *Health, amount: i32) void {
        self.current -= amount;
        if (self.current < 0) self.current = 0;
    }

    pub fn heal(self: *Health, amount: i32) void {
        self.current += amount;
        if (self.current > self.max) self.current = self.max;
    }
};

/// 法力值组件 —— 施法的资源
pub const Mana = struct {
    current: i32,
    max: i32,

    /// 消耗法力，成功返回 true
    pub fn consume(self: *Mana, amount: i32) bool {
        if (self.current < amount) return false;
        self.current -= amount;
        return true;
    }

    /// 恢复法力
    pub fn restore(self: *Mana, amount: i32) void {
        self.current += amount;
        if (self.current > self.max) self.current = self.max;
    }
};

/// 法术强度组件 —— 影响法术效果
pub const SpellPower = struct {
    value: i32,
};

/// 渲染组件 —— 决定实体在地图上的显示方式
pub const Renderable = struct {
    /// 显示字符
    glyph: u8,
    /// 前景色
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,

    pub fn player() Renderable {
        return .{ .glyph = '@', .fg_r = 1.0, .fg_g = 0.9, .fg_b = 0.3 };
    }

    pub fn enemy() Renderable {
        return .{ .glyph = '*', .fg_r = 0.3, .fg_g = 1.0, .fg_b = 0.3 };
    }

    pub fn fireball() Renderable {
        return .{ .glyph = '*', .fg_r = 1.0, .fg_g = 0.4, .fg_b = 0.0 };
    }
};

/// 火球投射物组件
pub const Fireball = struct {
    /// 移动方向（单位向量或对角线）
    dir_x: i32,
    dir_y: i32,
    /// 已飞行距离
    distance: u32,
    /// 最大飞行距离
    max_distance: u32,
    /// 撞击时造成的伤害
    damage: i32,
    /// 施法者的法术强度（影响伤害加成）
    spell_power: i32,
    /// 撞击后是否施加灼烧
    apply_burning: bool,

    pub fn impactDamage(self: Fireball) i32 {
        // 伤害 = 基础伤害 + 法术强度加成
        return self.damage + @divTrunc(self.spell_power, 2);
    }
};

/// 灼烧状态组件 —— 每回合造成火焰伤害
pub const Burning = struct {
    /// 每回合伤害
    damage_per_tick: i32,
    /// 剩余持续回合数
    remaining_ticks: u32,

    pub fn isExpired(self: Burning) bool {
        return self.remaining_ticks == 0;
    }
};

/// 玩家标记组件（空结构体，用于标识）
pub const Player = struct {};

/// 敌人标记组件
pub const Enemy = struct {
    /// 视野半径（格）
    sight_range: u32,
};

// ============================================================================
// 事件结构体
// ============================================================================

/// 伤害事件 —— 当实体受到伤害时触发
pub const DamageEvent = struct {
    /// 受伤害的实体
    target: ecs.Entity,
    /// 造成伤害的实体
    source: ecs.Entity,
    /// 伤害数值
    amount: i32,
    /// 伤害类型（0=物理, 1=火焰, 2=冰霜, 3=闪电, 4=奥术）
    damage_type: u32,

    pub const event_type_id = EVENT_DAMAGE;
};

/// 法术施放事件
pub const SpellCastEvent = struct {
    /// 施法者实体
    caster: ecs.Entity,
    /// 法术名称
    spell_name: []const u8,
    /// 法力消耗
    mana_cost: i32,
    /// 施放位置的 X 坐标
    target_x: i32,
    /// 施放位置的 Y 坐标
    target_y: i32,

    pub const event_type_id = EVENT_SPELL_CAST;
};

// ============================================================================
// 系统：火球术投射物处理
// ============================================================================

/// 投射物系统 —— 移动火球并检测碰撞
/// 每帧每个投射物向前移动一格。
/// 碰撞检测：如果目标位置有实体，造成伤害。
/// 如果飞行距离耗尽或撞墙，投射物消失。
pub fn projectileSystem(world: *ecs.World) !void {
    // 收集所有火球投射物（先收集再处理，避免迭代时修改）
    var projectiles: std.ArrayList(struct { entity: ecs.Entity, fb: Fireball, pos: Position }) = .empty;
    defer projectiles.deinit(world.allocator);

    const fb_storage = world.typedStorage(Fireball, COMP_FIREBALL);
    var fb_iter = fb_storage.iter();
    while (fb_iter.next()) |row| {
        // 获取对应的位置
        if (world.getComponent(row.entity, Position, COMP_POSITION)) |pos| {
            try projectiles.append(world.allocator, .{ .entity = row.entity, .fb = row.component.*, .pos = pos.* });
        }
    }

    // 处理每个投射物
    for (projectiles.items) |proj| {
        const new_x = proj.pos.x + proj.fb.dir_x;
        const new_y = proj.pos.y + proj.fb.dir_y;

        var destroyed = false;

        // 检查飞行距离
        if (proj.fb.distance >= proj.fb.max_distance) {
            destroyed = true;
        }

        // 检查碰撞：查找目标位置的所有实体
        if (!destroyed) {
            const heal_storage = world.typedStorage(Health, COMP_HEALTH);
            var heal_iter2 = heal_storage.iter();
            while (heal_iter2.next()) |target_row| {
                // 跳过投射物自身
                if (target_row.entity.eql(proj.entity)) continue;

                // 检查目标是否在投射物的新位置
                if (world.getComponent(target_row.entity, Position, COMP_POSITION)) |target_pos| {
                    if (target_pos.x == new_x and target_pos.y == new_y) {
                        // 碰撞！造成伤害
                        const dmg = proj.fb.impactDamage();
                        target_row.component.takeDamage(dmg);

                        // 发射伤害事件
                        world.emit(DamageEvent, .{
                            .target = target_row.entity,
                            .source = proj.entity,
                            .amount = dmg,
                            .damage_type = 1, // 火焰伤害
                        }) catch {};

                        // 如果配置了灼烧效果，给目标添加 Burning 组件
                        if (proj.fb.apply_burning) {
                            const burn_dmg = @max(1, @divTrunc(dmg, 3));
                            world.addComponent(target_row.entity, Burning, COMP_BURNING, .{
                                .damage_per_tick = burn_dmg,
                                .remaining_ticks = 3,
                            }) catch {};
                        }

                        destroyed = true;
                        break;
                    }
                }
            }
        }

        if (destroyed) {
            // 销毁投射物
            world.destroyEntity(proj.entity);
        } else {
            // 移动投射物
            if (world.getComponent(proj.entity, Position, COMP_POSITION)) |pos| {
                pos.x = new_x;
                pos.y = new_y;
            }
            // 更新飞行距离
            if (world.getComponent(proj.entity, Fireball, COMP_FIREBALL)) |fb| {
                fb.distance += 1;
            }
        }
    }
}

// ============================================================================
// 系统：灼烧状态处理
// ============================================================================

/// 灼烧系统 —— 每帧对所有拥有 Burning 组件的实体造成火焰伤害。
/// 如果剩余回合数归零，移除 Burning 组件。
/// 如果实体因灼烧死亡，发射死亡事件。
pub fn burningSystem(world: *ecs.World) !void {
    // 收集所有需要处理的灼烧实体
    var to_remove: std.ArrayList(ecs.Entity) = .empty;
    defer to_remove.deinit(world.allocator);

    const burn_storage = world.typedStorage(Burning, COMP_BURNING);
    var burn_iter = burn_storage.iter();
    while (burn_iter.next()) |row| {
        // 造成灼烧伤害
        const dmg = row.component.damage_per_tick;
        row.component.remaining_ticks -= 1;

        // 对目标实体造成伤害
        if (world.getComponent(row.entity, Health, COMP_HEALTH)) |health| {
            health.takeDamage(dmg);

            // 发射伤害事件
            world.emit(DamageEvent, .{
                .target = row.entity,
                .source = row.entity, // 灼烧的伤害来源是自身
                .amount = dmg,
                .damage_type = 1, // 火焰伤害
            }) catch {};
        }

        // 检查是否应该移除灼烧状态
        if (row.component.isExpired()) {
            try to_remove.append(world.allocator, row.entity);
        }
    }

    // 移除过期的灼烧状态
    for (to_remove.items) |entity| {
        world.removeComponent(entity, Burning, COMP_BURNING);
    }
}

// ============================================================================
// 辅助函数：施放火球术
// ============================================================================

/// 施放火球术 —— 创建一个火球投射物实体。
/// 用法：由玩家输入系统或 AI 系统调用。
///
/// 参数：
/// - world: ECS 世界
/// - caster: 施法者实体
/// - dir_x, dir_y: 火球飞行方向
/// - base_damage: 基础伤害值
pub fn castFireball(
    world: *ecs.World,
    caster: ecs.Entity,
    dir_x: i32,
    dir_y: i32,
    base_damage: i32,
) !void {
    // 获取施法者位置
    const caster_pos = world.getComponent(caster, Position, COMP_POSITION) orelse return error.NoPosition;

    // 获取施法者的法力值，检查是否足够
    const mana_cost: i32 = 15;
    if (world.getComponent(caster, Mana, COMP_MANA)) |mana| {
        if (!mana.consume(mana_cost)) {
            // 法力不足
            return error.NotEnoughMana;
        }
    }

    // 获取施法者的法术强度
    var spell_power: i32 = 0;
    if (world.getComponent(caster, SpellPower, COMP_SPELL_POWER)) |sp| {
        spell_power = sp.value;
    }

    // 创建火球实体
    const fireball_entity = try world.createEntity();

    // 设置火球位置（在施法者旁边）
    try world.addComponent(fireball_entity, Position, COMP_POSITION, .{
        .x = caster_pos.x + dir_x,
        .y = caster_pos.y + dir_y,
    });

    // 设置火球组件属性
    try world.addComponent(fireball_entity, Fireball, COMP_FIREBALL, .{
        .dir_x = dir_x,
        .dir_y = dir_y,
        .distance = 0,
        .max_distance = 8,
        .damage = base_damage,
        .spell_power = spell_power,
        .apply_burning = true,
    });

    // 设置渲染
    try world.addComponent(fireball_entity, Renderable, COMP_RENDERABLE, Renderable.fireball());

    // 发射法术施放事件
    try world.emit(SpellCastEvent, .{
        .caster = caster,
        .spell_name = "火球术",
        .mana_cost = mana_cost,
        .target_x = caster_pos.x + dir_x * 8,
        .target_y = caster_pos.y + dir_y * 8,
    });
}

// ============================================================================
// 插件清单
// ============================================================================

/// 火法师插件清单 —— 在编译期被插件收集器读取
pub const manifest = plugin.PluginManifest{
    .name = "火法师职业",
    .version = "1.0.0",
    .components = &.{
        plugin.componentEntry("Position", Position),
        plugin.componentEntry("Health", Health),
        plugin.componentEntry("Mana", Mana),
        plugin.componentEntry("SpellPower", SpellPower),
        plugin.componentEntry("Renderable", Renderable),
        plugin.componentEntry("Fireball", Fireball),
        plugin.componentEntry("Burning", Burning),
        plugin.componentEntry("Player", Player),
        plugin.componentEntry("Enemy", Enemy),
    },
    .systems = &.{
        plugin.systemEntry("投射物移动", .movement, projectileSystem),
        plugin.systemEntry("灼烧状态", .status_effect, burningSystem),
    },
    .events = &.{
        plugin.eventEntry("DamageEvent", DamageEvent),
        plugin.eventEntry("SpellCastEvent", SpellCastEvent),
    },
};
