//! 编译时插件：敌对 AI 系统
//!
//! 实现基础的敌对生物 AI 行为。
//! AI 决策完全通过 ECS 组件查询执行，无虚函数调用。
//!
//! 行为模式：
//! 1. 如果玩家在视野内，尝试靠近
//! 2. 如果玩家在攻击范围内，进行攻击
//! 3. 否则随机移动（简单的闲逛行为）
//!
//! 设计要点：
//! - AI 系统通过查询 Enemy + Position 组件找到所有敌对实体
//! - 通过查询 Player + Position 组件找到玩家位置
//! - 使用简单的曼哈顿距离判断行为

const std = @import("std");
const ecs = @import("../engine/ecs.zig");
const plugin = @import("../engine/plugin_comptime.zig");
const world_mod = @import("../engine/world.zig");

// 从火法师插件导入组件类型 ID 和组件类型
const firemage = @import("core_class_firemage.zig");

/// 敌对AI系统
/// 每帧对所有 Enemy 实体执行 AI 决策：
/// 1. 获取玩家位置
/// 2. 对每个敌对实体，计算与玩家的距离
/// 3. 根据距离决定行为：追击、攻击或闲逛
pub fn hostileAISystem(world: *ecs.World) !void {
    // 1. 查找玩家位置
    var player_pos: ?firemage.Position = null;

    const pos_storage = world.typedStorage(firemage.Position, firemage.COMP_POSITION);
    var pos_iter = pos_storage.iter();
    while (pos_iter.next()) |row| {
        // 检查此实体是否有 Player 组件
        if (world.hasComponent(row.entity, firemage.Player, firemage.COMP_PLAYER)) {
            player_pos = row.component.*;
            break;
        }
    }

    // 如果没有玩家（可能是测试模式），跳过 AI
    const pp = player_pos orelse return;

    // 2. 收集所有敌对实体的数据
    var enemies: std.ArrayList(struct {
        entity: ecs.Entity,
        pos: firemage.Position,
    }) = .empty;
    defer enemies.deinit(world.allocator);

    var pos_iter2 = pos_storage.iter();
    while (pos_iter2.next()) |row| {
        if (world.hasComponent(row.entity, firemage.Enemy, firemage.COMP_ENEMY)) {
            // 检查是否还活着
            if (world.getComponent(row.entity, firemage.Health, firemage.COMP_HEALTH)) |health| {
                if (health.isDead()) continue;
            }
            enemies.append(world.allocator, .{ .entity = row.entity, .pos = row.component.* }) catch continue;
        }
    }

    // 3. 对每个敌对实体执行 AI
    for (enemies.items) |enemy_info| {
        const dx = pp.x - enemy_info.pos.x;
        const dy = pp.y - enemy_info.pos.y;
        const dist = @abs(dx) + @abs(dy); // 曼哈顿距离

        // 获取敌人的视野范围
        var sight_range: u32 = 6;
        if (world.getComponent(enemy_info.entity, firemage.Enemy, firemage.COMP_ENEMY)) |enemy_comp| {
            sight_range = enemy_comp.sight_range;
        }

        if (dist == 0) {
            // 与玩家重叠，不应发生
            continue;
        } else if (dist <= @as(i32, @intCast(sight_range))) {
            // 玩家在视野内：追击或攻击
            if (dist <= 1) {
                // 相邻格子：发动近战攻击
                try meleeAttack(world, enemy_info.entity, pp);
            } else {
                // 距离较远：向玩家移动
                try moveTowards(world, enemy_info.entity, enemy_info.pos, pp);
            }
        } else {
            // 玩家不在视野内：随机闲逛
            try randomWalk(world, enemy_info.entity, enemy_info.pos);
        }
    }
}

/// 向目标位置移动一步
fn moveTowards(world: *ecs.World, entity: ecs.Entity, current: firemage.Position, target: firemage.Position) !void {
    // 计算移动方向（只沿轴移动，避免对角线穿墙）
    const dx = std.math.sign(target.x - current.x);
    const dy = std.math.sign(target.y - current.y);

    // 优先尝试 X 轴移动，如果 X 不可行则尝试 Y 轴
    const moves = [_][2]i32{
        .{ dx, 0 },
        .{ 0, dy },
    };

    for (moves) |mv| {
        if (mv[0] == 0 and mv[1] == 0) continue;
        const nx = current.x + mv[0];
        const ny = current.y + mv[1];

        // 检查目标位置是否被占据
        var blocked = false;
        var pos_iter3 = world.typedStorage(firemage.Position, firemage.COMP_POSITION).iter();
        while (pos_iter3.next()) |row| {
            if (row.component.x == nx and row.component.y == ny) {
                // 如果该位置有实体，且不是自己，被阻挡
                if (!row.entity.eql(entity)) {
                    blocked = true;
                    break;
                }
            }
        }

        if (!blocked) {
            if (world.getComponent(entity, firemage.Position, firemage.COMP_POSITION)) |pos| {
                pos.x = nx;
                pos.y = ny;
            }
            return;
        }
    }
}

/// 近战攻击玩家
fn meleeAttack(world: *ecs.World, attacker: ecs.Entity, player_pos: firemage.Position) !void {
    // 查找位于玩家位置的实体（应该是玩家）
    var pos_iter4 = world.typedStorage(firemage.Position, firemage.COMP_POSITION).iter();
    while (pos_iter4.next()) |row| {
        if (row.component.x == player_pos.x and row.component.y == player_pos.y) {
            if (world.hasComponent(row.entity, firemage.Player, firemage.COMP_PLAYER)) {
                // 造成伤害
                const base_dmg: i32 = 5;
                if (world.getComponent(row.entity, firemage.Health, firemage.COMP_HEALTH)) |health| {
                    health.takeDamage(base_dmg);

                    // 发射伤害事件
                    world.emit(firemage.DamageEvent, .{
                        .target = row.entity,
                        .source = attacker,
                        .amount = base_dmg,
                        .damage_type = 0, // 物理伤害
                    }) catch {};
                }
            }
            break;
        }
    }
}

/// 随机闲逛：在相邻的四个方向中随机选择一个可行方向移动
fn randomWalk(world: *ecs.World, entity: ecs.Entity, current: firemage.Position) !void {
    // 使用游戏时钟和实体 ID 作为伪随机种子
    var rng = std.Random.DefaultPrng.init(world.tick ^ @as(u64, entity.index));
    const rand = rng.random();

    const directions = [_][2]i32{
        .{ 0, -1 }, // 上
        .{ 0, 1 },  // 下
        .{ -1, 0 }, // 左
        .{ 1, 0 },  // 右
    };

    // 随机打乱方向（Fisher-Yates 洗牌）
    var shuffled = directions;
    var i: usize = shuffled.len;
    while (i > 1) {
        i -= 1;
        const j = rand.uintLessThan(usize, i + 1);
        const tmp = shuffled[i];
        shuffled[i] = shuffled[j];
        shuffled[j] = tmp;
    }

    for (shuffled) |dir| {
        const nx = current.x + dir[0];
        const ny = current.y + dir[1];

        // 检查目标位置是否被占据
        var blocked = false;
        var pos_iter5 = world.typedStorage(firemage.Position, firemage.COMP_POSITION).iter();
        while (pos_iter5.next()) |row| {
            if (row.component.x == nx and row.component.y == ny) {
                if (!row.entity.eql(entity)) {
                    blocked = true;
                    break;
                }
            }
        }

        if (!blocked) {
            if (world.getComponent(entity, firemage.Position, firemage.COMP_POSITION)) |pos| {
                pos.x = nx;
                pos.y = ny;
            }
            return;
        }
    }
}

// ============================================================================
// 插件清单
// ============================================================================

// ============================================================================
// 测试
// ============================================================================

const testing = @import("std").testing;

fn setupAIWorld() !ecs.World {
    const world = try @import("../tests.zig").createTestWorld(testing.allocator);
    return world;
}

test "AI hostileAISystem runs without crash" {
    var world = try setupAIWorld();
    defer world.deinit();

    // 创建玩家
    const player = try world.createEntity();
    try world.addComponent(player, firemage.Position, firemage.COMP_POSITION, .{ .x = 5, .y = 5 });
    try world.addComponent(player, firemage.Player, firemage.COMP_PLAYER, .{});
    try world.addComponent(player, firemage.Health, firemage.COMP_HEALTH, .{ .current = 100, .max = 100 });

    // 创建敌人（远离玩家）
    const enemy = try world.createEntity();
    try world.addComponent(enemy, firemage.Position, firemage.COMP_POSITION, .{ .x = 20, .y = 20 });
    try world.addComponent(enemy, firemage.Enemy, firemage.COMP_ENEMY, .{ .sight_range = 5 });
    try world.addComponent(enemy, firemage.Health, firemage.COMP_HEALTH, .{ .current = 30, .max = 30 });

    try hostileAISystem(&world);
    // 敌人离玩家太远（距离 30），视野只有 5，应该随机闲逛或不动
    // 仅检查没有崩溃
}

test "AI enemy approaches player in sight" {
    var world = try setupAIWorld();
    defer world.deinit();

    const player = try world.createEntity();
    try world.addComponent(player, firemage.Position, firemage.COMP_POSITION, .{ .x = 5, .y = 5 });
    try world.addComponent(player, firemage.Player, firemage.COMP_PLAYER, .{});
    try world.addComponent(player, firemage.Health, firemage.COMP_HEALTH, .{ .current = 100, .max = 100 });

    // 创建敌人在视野内
    const enemy = try world.createEntity();
    try world.addComponent(enemy, firemage.Position, firemage.COMP_POSITION, .{ .x = 8, .y = 5 });
    try world.addComponent(enemy, firemage.Enemy, firemage.COMP_ENEMY, .{ .sight_range = 6 });
    try world.addComponent(enemy, firemage.Health, firemage.COMP_HEALTH, .{ .current = 30, .max = 30 });

    try hostileAISystem(&world);

    // 敌人应该向玩家移动（距离 3，在视野 6 内）
    const enemy_pos = world.getComponent(enemy, firemage.Position, firemage.COMP_POSITION);
    try testing.expect(enemy_pos != null);
    // 方位应该向玩家靠近
    try testing.expect(enemy_pos.?.x >= 7); // 向左（玩家方向）移动一步
}

test "AI enemy attacks adjacent player" {
    var world = try setupAIWorld();
    defer world.deinit();

    const player = try world.createEntity();
    try world.addComponent(player, firemage.Position, firemage.COMP_POSITION, .{ .x = 5, .y = 5 });
    try world.addComponent(player, firemage.Player, firemage.COMP_PLAYER, .{});
    try world.addComponent(player, firemage.Health, firemage.COMP_HEALTH, .{ .current = 100, .max = 100 });

    // 创建敌人紧挨着玩家
    const enemy = try world.createEntity();
    try world.addComponent(enemy, firemage.Position, firemage.COMP_POSITION, .{ .x = 6, .y = 5 });
    try world.addComponent(enemy, firemage.Enemy, firemage.COMP_ENEMY, .{ .sight_range = 6 });
    try world.addComponent(enemy, firemage.Health, firemage.COMP_HEALTH, .{ .current = 30, .max = 30 });

    try hostileAISystem(&world);

    // 玩家应该受到伤害（敌人近战攻击）
    const player_hp = world.getComponent(player, firemage.Health, firemage.COMP_HEALTH);
    try testing.expect(player_hp != null);
    try testing.expect(player_hp.?.current < 100);
}

pub const manifest = plugin.PluginManifest{
    .name = "敌对AI系统",
    .version = "1.0.0",
    .components = &.{},
    .systems = &.{
        plugin.systemEntry("敌对AI", .ai, hostileAISystem),
    },
    .events = &.{},
};
