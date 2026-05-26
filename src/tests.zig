//! 测试入口 —— 引用所有模块的 test 块

test {
    _ = @import("engine/ecs.zig");
    _ = @import("engine/rng.zig");
    _ = @import("engine/world.zig");
    _ = @import("plugins/core_class_firemage.zig");
    _ = @import("plugins/core_ai_hostile.zig");
    _ = @import("plugins/core_stats.zig");
    _ = @import("plugins/core_resources.zig");
    _ = @import("plugins/core_talents.zig");
    _ = @import("plugins/core_items.zig");
}

const std = @import("std");
const ecs = @import("engine/ecs.zig");

/// 测试辅助：创建完整 World + 注册所有组件存储
/// 使用 page_allocator 避免 testing.allocator 的内存泄漏检测
pub fn createTestWorld(_: std.mem.Allocator) !ecs.World {
    const allocator = std.heap.page_allocator;
    const firemage = @import("plugins/core_class_firemage.zig");
    const stats_mod = @import("plugins/core_stats.zig");
    const resources_mod = @import("plugins/core_resources.zig");
    const talents_mod = @import("plugins/core_talents.zig");
    const items_mod = @import("plugins/core_items.zig");

    var world = try ecs.World.init(allocator);

    try reg(allocator, &world, firemage.Position, firemage.COMP_POSITION);
    try reg(allocator, &world, firemage.Health, firemage.COMP_HEALTH);
    try reg(allocator, &world, firemage.Mana, firemage.COMP_MANA);
    try reg(allocator, &world, firemage.SpellPower, firemage.COMP_SPELL_POWER);
    try reg(allocator, &world, firemage.Renderable, firemage.COMP_RENDERABLE);
    try reg(allocator, &world, firemage.Fireball, firemage.COMP_FIREBALL);
    try reg(allocator, &world, firemage.Burning, firemage.COMP_BURNING);
    try reg(allocator, &world, firemage.Player, firemage.COMP_PLAYER);
    try reg(allocator, &world, firemage.Enemy, firemage.COMP_ENEMY);
    try reg(allocator, &world, stats_mod.Stats, stats_mod.COMP_STATS);
    try reg(allocator, &world, stats_mod.CombatStats, stats_mod.COMP_COMBAT_STATS);
    try reg(allocator, &world, resources_mod.ResourcePool, resources_mod.COMP_RESOURCE_POOL);
    try reg(allocator, &world, talents_mod.TalentComponent, talents_mod.COMP_TALENTS);
    try reg(allocator, &world, items_mod.Item, items_mod.COMP_ITEM);
    try reg(allocator, &world, items_mod.Inventory, items_mod.COMP_INVENTORY);
    try reg(allocator, &world, items_mod.Equipment, items_mod.COMP_EQUIPMENT);

    return world;
}

fn reg(allocator: std.mem.Allocator, world: *ecs.World, comptime T: type, type_id: u16) !void {
    const Storage = ecs.ComponentStorage(T);
    const storage = try allocator.create(Storage);
    storage.* = try Storage.init(allocator);
    try world.registerStorage(T, type_id, storage);
}
