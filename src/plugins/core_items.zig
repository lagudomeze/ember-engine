//! 编译时插件：物品与装备系统
//!
//! 对应原 ToME4 ActorInventory、Object 模块。
//!
//! 组件：
//! - Item: 物品数据（名称、类型、属性加成）
//! - Inventory: 物品栏（携带的物品列表）
//! - Equipment: 装备槽（已装备的物品映射）
//!
//! 系统：
//! - equipmentRecalcSystem: 装备属性加成重算

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");

const firemage = @import("core_class_firemage.zig");
const stats_mod = @import("core_stats.zig");

// ============================================================================
// 组件类型 ID（从 14 开始）
// ============================================================================

pub const COMP_ITEM: u16 = 14;
pub const COMP_INVENTORY: u16 = 15;
pub const COMP_EQUIPMENT: u16 = 16;

pub const EVENT_ITEM_PICKUP: u16 = 5;
pub const EVENT_ITEM_EQUIP: u16 = 6;

// ============================================================================
// 装备槽位 —— 对应 ToME4 的装备位置
// ============================================================================

pub const EquipSlot = enum(u8) {
    mainhand, // 主手（武器）
    offhand, // 副手（盾牌/副武器/法器）
    body, // 身体（护甲）
    head, // 头部（头盔）
    hands, // 手部（手套）
    feet, // 脚部（鞋子）
    cloak, // 披风
    amulet, // 项链
    ring1, // 戒指 1
    ring2, // 戒指 2
    tool, // 工具
    lite, // 灯具（光照）
    ammo, // 弹药

    pub fn nameCN(self: EquipSlot) []const u8 {
        return switch (self) {
            .mainhand => "主手",
            .offhand => "副手",
            .body => "身体",
            .head => "头部",
            .hands => "手部",
            .feet => "脚部",
            .cloak => "披风",
            .amulet => "项链",
            .ring1 => "戒指1",
            .ring2 => "戒指2",
            .tool => "工具",
            .lite => "灯具",
            .ammo => "弹药",
        };
    }
};

// ============================================================================
// 物品类型
// ============================================================================

pub const ItemType = enum(u8) {
    weapon, // 武器
    armor, // 护甲
    ring, // 戒指
    amulet, // 项链
    gem, // 宝石
    scroll, // 卷轴
    potion, // 药水
    wand, // 魔杖
    lite, // 灯具
    tool, // 工具
    misc, // 杂项
};

// ============================================================================
// 组件定义
// ============================================================================

/// 物品组件 —— 描述一个物品实体（掉在地上的物品有 Position + Item）
pub const Item = struct {
    name: []const u8 = "", // 物品名称
    type: ItemType = .misc, // 物品类型
    slot: ?EquipSlot = null, // 可装备到哪个槽位（null=不可装备）
    weight: f64 = 0, // 重量

    // 属性加成（装备时生效）
    str_bonus: i32 = 0,
    dex_bonus: i32 = 0,
    con_bonus: i32 = 0,
    mag_bonus: i32 = 0,
    wil_bonus: i32 = 0,
    cun_bonus: i32 = 0,

    // 战斗属性加成
    armor_bonus: i32 = 0,
    damage_bonus: i32 = 0,
    accuracy_bonus: i32 = 0,
    crit_bonus: f64 = 0,
    resist_all: i32 = 0,
    fire_resist: i32 = 0,

    /// 总加成属性点数（作为物品质量参考）
    pub fn totalBonus(self: Item) i32 {
        return self.str_bonus + self.dex_bonus + self.con_bonus +
            self.mag_bonus + self.wil_bonus + self.cun_bonus +
            self.armor_bonus + self.damage_bonus + self.accuracy_bonus;
    }

    /// 是否为可装备物品
    pub fn isEquippable(self: Item) bool {
        return self.slot != null;
    }
};

/// 物品栏组件 —— 持有者携带的物品列表
pub const Inventory = struct {
    items: std.ArrayList(ecs.Entity) = .empty, // 物品实体列表
    max_items: u32 = 20, // 最大携带数量
};

/// 装备组件 —— 记录每个槽位装备的物品
pub const Equipment = struct {
    /// 槽位 → 物品实体映射（用选项表示空槽位）
    mainhand: ecs.Entity = ecs.Entity.dead(),
    offhand: ecs.Entity = ecs.Entity.dead(),
    body: ecs.Entity = ecs.Entity.dead(),
    head: ecs.Entity = ecs.Entity.dead(),
    hands: ecs.Entity = ecs.Entity.dead(),
    feet: ecs.Entity = ecs.Entity.dead(),
    cloak: ecs.Entity = ecs.Entity.dead(),
    amulet: ecs.Entity = ecs.Entity.dead(),
    ring1: ecs.Entity = ecs.Entity.dead(),
    ring2: ecs.Entity = ecs.Entity.dead(),
    tool: ecs.Entity = ecs.Entity.dead(),
    lite: ecs.Entity = ecs.Entity.dead(),
    ammo: ecs.Entity = ecs.Entity.dead(),

    /// 获取某槽位的物品
    pub fn getSlot(self: *const Equipment, slot: EquipSlot) ecs.Entity {
        return switch (slot) {
            .mainhand => self.mainhand,
            .offhand => self.offhand,
            .body => self.body,
            .head => self.head,
            .hands => self.hands,
            .feet => self.feet,
            .cloak => self.cloak,
            .amulet => self.amulet,
            .ring1 => self.ring1,
            .ring2 => self.ring2,
            .tool => self.tool,
            .lite => self.lite,
            .ammo => self.ammo,
        };
    }

    /// 设置某槽位的物品
    pub fn setSlot(self: *Equipment, slot: EquipSlot, entity: ecs.Entity) void {
        switch (slot) {
            .mainhand => self.mainhand = entity,
            .offhand => self.offhand = entity,
            .body => self.body = entity,
            .head => self.head = entity,
            .hands => self.hands = entity,
            .feet => self.feet = entity,
            .cloak => self.cloak = entity,
            .amulet => self.amulet = entity,
            .ring1 => self.ring1 = entity,
            .ring2 => self.ring2 = entity,
            .tool => self.tool = entity,
            .lite => self.lite = entity,
            .ammo => self.ammo = entity,
        }
    }
};

// ============================================================================
// 事件
// ============================================================================

pub const ItemPickupEvent = struct {
    entity: ecs.Entity,
    item: ecs.Entity,
    item_name: []const u8,

    pub const event_type_id = EVENT_ITEM_PICKUP;
};

pub const ItemEquipEvent = struct {
    entity: ecs.Entity,
    item: ecs.Entity,
    slot: EquipSlot,

    pub const event_type_id = EVENT_ITEM_EQUIP;
};

// ============================================================================
// 物品工厂函数
// ============================================================================

/// 创建一把剑
pub fn createSword(world: *ecs.World, name: []const u8, damage_bonus: i32) !ecs.Entity {
    const entity = try world.createEntity();
    try world.addComponent(entity, Item, COMP_ITEM, .{
        .name = name,
        .type = .weapon,
        .slot = .mainhand,
        .weight = 3.0,
        .damage_bonus = damage_bonus,
        .str_bonus = @divTrunc(damage_bonus, 3),
    });
    return entity;
}

/// 创建一件护甲
pub fn createArmor(world: *ecs.World, name: []const u8, armor_bonus: i32) !ecs.Entity {
    const entity = try world.createEntity();
    try world.addComponent(entity, Item, COMP_ITEM, .{
        .name = name,
        .type = .armor,
        .slot = .body,
        .weight = 8.0,
        .armor_bonus = armor_bonus,
        .con_bonus = @divTrunc(armor_bonus, 4),
    });
    return entity;
}

/// 创建一枚戒指
pub fn createRing(world: *ecs.World, name: []const u8, stat_bonus: i32) !ecs.Entity {
    const entity = try world.createEntity();
    try world.addComponent(entity, Item, COMP_ITEM, .{
        .name = name,
        .type = .ring,
        .slot = .ring1,
        .weight = 0.1,
        .mag_bonus = stat_bonus,
        .wil_bonus = stat_bonus,
    });
    return entity;
}

/// 创建一瓶治疗药水
pub fn createHealingPotion(world: *ecs.World) !ecs.Entity {
    const entity = try world.createEntity();
    try world.addComponent(entity, Item, COMP_ITEM, .{
        .name = "治疗药水",
        .type = .potion,
        .weight = 0.2,
    });
    return entity;
}

// ============================================================================
// 系统
// ============================================================================

/// 将某槽位装备的属性加成应用到 Stats
fn applySlotStats(slot: EquipSlot, equip: *const Equipment, world: *ecs.World, stats: *stats_mod.Stats, combat: ?*stats_mod.CombatStats) void {
    const item_entity = equip.getSlot(slot);
    if (!item_entity.isAlive()) return;

    const item = world.getComponent(item_entity, Item, COMP_ITEM) orelse return;

    stats.str += item.str_bonus;
    stats.dex += item.dex_bonus;
    stats.con += item.con_bonus;
    stats.mag += item.mag_bonus;
    stats.wil += item.wil_bonus;
    stats.cun += item.cun_bonus;

    if (combat) |c| {
        c.armor += item.armor_bonus;
        c.all_resist += item.resist_all;
        c.fire_resist += item.fire_resist;
    }
}

/// 装备属性重算系统 —— 从装备物品的加成重新计算角色属性
pub fn equipmentRecalcSystem(world: *ecs.World) !void {
    const equip_storage = world.typedStorage(Equipment, COMP_EQUIPMENT);
    var equip_iter = equip_storage.iter();
    while (equip_iter.next()) |row| {
        if (world.getComponent(row.entity, stats_mod.Stats, stats_mod.COMP_STATS)) |stats| {
            stats.* = .{};

            var combat_ptr: ?*stats_mod.CombatStats = null;
            if (world.getComponent(row.entity, stats_mod.CombatStats, stats_mod.COMP_COMBAT_STATS)) |combat| {
                combat.* = .{};
                combat_ptr = combat;
            }

            // 遍历所有装备槽
            applySlotStats(.mainhand, row.component, world, stats, combat_ptr);
            applySlotStats(.offhand, row.component, world, stats, combat_ptr);
            applySlotStats(.body, row.component, world, stats, combat_ptr);
            applySlotStats(.head, row.component, world, stats, combat_ptr);
            applySlotStats(.hands, row.component, world, stats, combat_ptr);
            applySlotStats(.feet, row.component, world, stats, combat_ptr);
            applySlotStats(.cloak, row.component, world, stats, combat_ptr);
            applySlotStats(.amulet, row.component, world, stats, combat_ptr);
            applySlotStats(.ring1, row.component, world, stats, combat_ptr);
            applySlotStats(.ring2, row.component, world, stats, combat_ptr);
            applySlotStats(.tool, row.component, world, stats, combat_ptr);
            applySlotStats(.lite, row.component, world, stats, combat_ptr);
            applySlotStats(.ammo, row.component, world, stats, combat_ptr);
        }
    }
}

/// 装备物品到指定槽位
pub fn equipItem(world: *ecs.World, entity: ecs.Entity, item_entity: ecs.Entity) !void {
    if (world.getComponent(item_entity, Item, COMP_ITEM)) |item| {
        const slot = item.slot orelse return; // 不可装备

        if (world.getComponent(entity, Equipment, COMP_EQUIPMENT)) |equip| {
            // 如果槽位已有物品，先卸下
            const old_item = equip.getSlot(slot);
            if (old_item.isAlive()) {
                // 将旧物品放回物品栏
                try unequipItem(world, entity, slot);
            }

            // 装备新物品
            equip.setSlot(slot, item_entity);

            // 从物品栏移除（如果存在）
            if (world.getComponent(entity, Inventory, COMP_INVENTORY)) |inv| {
                for (inv.items.items, 0..) |inv_item, i| {
                    if (inv_item.eql(item_entity)) {
                        _ = inv.items.swapRemove(i);
                        break;
                    }
                }
            }

            // 发射装备事件
            try world.emit(ItemEquipEvent, .{
                .entity = entity,
                .item = item_entity,
                .slot = slot,
            });

            // 重算属性
            try equipmentRecalcSystem(world);
        }
    }
}

/// 卸下装备
pub fn unequipItem(world: *ecs.World, entity: ecs.Entity, slot: EquipSlot) !void {
    if (world.getComponent(entity, Equipment, COMP_EQUIPMENT)) |equip| {
        const item_entity = equip.getSlot(slot);
        if (!item_entity.isAlive()) return;

        // 放回物品栏
        if (world.getComponent(entity, Inventory, COMP_INVENTORY)) |inv| {
            try inv.items.append(world.allocator, item_entity);
        }

        // 清空槽位
        equip.setSlot(slot, ecs.Entity.dead());

        // 重算属性
        try equipmentRecalcSystem(world);
    }
}

// ============================================================================
// 插件清单
// ============================================================================

pub const manifest = plugin.PluginManifest{
    .name = "物品装备系统",
    .version = "1.0.0",
    .components = &.{
        plugin.componentEntry("Item", Item),
        plugin.componentEntry("Inventory", Inventory),
        plugin.componentEntry("Equipment", Equipment),
    },
    .systems = &.{
        plugin.systemEntry("装备属性重算", .status_effect, equipmentRecalcSystem),
    },
    .events = &.{
        plugin.eventEntry("ItemPickupEvent", ItemPickupEvent),
        plugin.eventEntry("ItemEquipEvent", ItemEquipEvent),
    },
};
