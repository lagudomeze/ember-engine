//! T-Engine Zig —— 游戏入口点
//!
//! 《Tales of Maj'Eyal: Zig Edition》
//!
//! 启动流程：
//! 1. 编译期收集所有插件清单，生成 SystemTable
//! 2. 创建渲染器（SDL2/OpenGL）
//! 3. 创建 ECS 世界并注册所有组件存储
//! 4. 初始化地图和初始实体（玩家、敌人）
//! 5. 进入主循环：输入 → 更新系统 → 渲染
//!
//! 控制说明：
//! - 方向键 / WASD：移动
//! - 数字键 1：施放火球术（向最后移动方向）
//! - ESC：退出游戏
//!
//! 显示说明：
//! - '@' 黄色：玩家
//! - '*' 红色：火球投射物
//! - '*' 绿色：敌对生物
//! - '#' 灰色：墙壁
//! - '.' 灰色：地板

const std = @import("std");
const ecs = @import("engine/ecs.zig");
const plugin = @import("engine/plugin_comptime.zig");
const world_mod = @import("engine/world.zig");
const renderer = @import("engine/renderer.zig");

// 导入编译时插件
const firemage_plugin = @import("plugins/core_class_firemage.zig");
const ai_plugin = @import("plugins/core_ai_hostile.zig");

// ============================================================================
// 编译期插件收集和系统表生成
// ============================================================================

/// 所有编译时融合插件的清单
const ALL_PLUGINS = .{
    firemage_plugin,
    ai_plugin,
};

/// 编译期生成的系统调度表 —— 零运行时开销
const system_table = blk: {
    const registry = plugin.PluginRegistry.collect(ALL_PLUGINS);
    break :blk registry.buildSystemTable();
};

// ============================================================================
// 游戏状态
// ============================================================================

/// 游戏主状态机
const GameState = struct {
    allocator: std.mem.Allocator,
    world: ecs.World,
    renderer: renderer.Renderer,
    input: renderer.InputState,
    map: world_mod.Map,
    player_entity: ecs.Entity,
    /// 玩家最后移动的方向（用于火球术施放方向）
    last_dir_x: i32,
    last_dir_y: i32,
    /// 日志消息
    log_messages: std.ArrayList([128]u8) = .empty,
    /// 是否在等待玩家输入（回合制模式）
    waiting_for_input: bool,

    fn init(allocator: std.mem.Allocator) !GameState {
        // 创建渲染器
        const rend = try renderer.Renderer.init(allocator, "T-Engine Zig —— Tales of Maj'Eyal", 960, 640, 20);

        // 创建 ECS 世界
        var w = try ecs.World.init(allocator);

        // 创建地图
        var map = try world_mod.Map.init(allocator, 12345);

        // 创建初始玩家实体
        const player = try w.createEntity();

        // 添加玩家位置
        try w.addComponent(player, firemage_plugin.Position, firemage_plugin.COMP_POSITION, .{
            .x = 5,
            .y = 5,
        });

        // 添加玩家生命值
        try w.addComponent(player, firemage_plugin.Health, firemage_plugin.COMP_HEALTH, .{
            .current = 100,
            .max = 100,
        });

        // 添加法力值
        try w.addComponent(player, firemage_plugin.Mana, firemage_plugin.COMP_MANA, .{
            .current = 100,
            .max = 100,
        });

        // 添加法术强度
        try w.addComponent(player, firemage_plugin.SpellPower, firemage_plugin.COMP_SPELL_POWER, .{
            .value = 20,
        });

        // 添加渲染
        try w.addComponent(player, firemage_plugin.Renderable, firemage_plugin.COMP_RENDERABLE, firemage_plugin.Renderable.player());

        // 标记为玩家
        try w.addComponent(player, firemage_plugin.Player, firemage_plugin.COMP_PLAYER, .{});

        // 确保玩家周围区块加载，并在附近生成敌人
        _ = try map.ensureChunk(0, 0);
        try spawnEnemies(&w, &map, player, allocator);

        return GameState{
            .allocator = allocator,
            .world = w,
            .renderer = rend,
            .input = renderer.InputState.init(),
            .map = map,
            .player_entity = player,
            .last_dir_x = 0,
            .last_dir_y = -1, // 默认向上
            .log_messages = .empty,
            .waiting_for_input = true,
        };
    }

    fn deinit(self: *GameState) void {
        self.log_messages.deinit(self.world.allocator);
        self.map.deinit();
        self.world.deinit();
        self.renderer.deinit();
    }

    /// 添加日志消息
    fn log(self: *GameState, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        var copy: [128]u8 = undefined;
        @memset(&copy, 0);
        @memcpy(copy[0..msg.len], msg);
        self.log_messages.append(self.world.allocator, copy) catch {};
        // 保持最近 10 条消息
        while (self.log_messages.items.len > 10) {
            _ = self.log_messages.orderedRemove(0);
        }
    }
};

// ============================================================================
// 初始实体生成
// ============================================================================

/// 在玩家附近生成敌对生物
fn spawnEnemies(world: *ecs.World, map: *world_mod.Map, player: ecs.Entity, allocator: std.mem.Allocator) !void {
    _ = map;

    // 获取玩家位置
    const player_pos = world.getComponent(player, firemage_plugin.Position, firemage_plugin.COMP_POSITION).?;

    // 使用简单的伪随机在玩家周围生成 5 个敌人
    const enemy_positions = [_][2]i32{
        .{ player_pos.x + 5, player_pos.y },
        .{ player_pos.x - 4, player_pos.y + 2 },
        .{ player_pos.x + 3, player_pos.y - 4 },
        .{ player_pos.x - 2, player_pos.y - 3 },
        .{ player_pos.x + 6, player_pos.y + 4 },
    };

    for (enemy_positions) |epos| {
        const enemy = try world.createEntity();

        try world.addComponent(enemy, firemage_plugin.Position, firemage_plugin.COMP_POSITION, .{
            .x = epos[0],
            .y = epos[1],
        });

        try world.addComponent(enemy, firemage_plugin.Health, firemage_plugin.COMP_HEALTH, .{
            .current = 30,
            .max = 30,
        });

        try world.addComponent(enemy, firemage_plugin.Renderable, firemage_plugin.COMP_RENDERABLE, firemage_plugin.Renderable.enemy());

        try world.addComponent(enemy, firemage_plugin.Enemy, firemage_plugin.COMP_ENEMY, .{
            .sight_range = 7,
        });

        _ = allocator;
    }
}

// ============================================================================
// 玩家输入处理
// ============================================================================

/// 处理玩家输入，返回 true 表示玩家执行了一个动作（消耗一个回合）
fn handlePlayerInput(state: *GameState) !bool {
    var action_taken = false;

    // 获取键盘状态
    const sc = renderer.Scancode;

    // 方向移动（WASD 和方向键）
    const move_pairs = [_]struct { key: renderer.Scancode, dx: i32, dy: i32 }{
        .{ .key = sc.up, .dx = 0, .dy = -1 },
        .{ .key = sc.down, .dx = 0, .dy = 1 },
        .{ .key = sc.left, .dx = -1, .dy = 0 },
        .{ .key = sc.right, .dx = 1, .dy = 0 },
        .{ .key = sc.w, .dx = 0, .dy = -1 },
        .{ .key = sc.s, .dx = 0, .dy = 1 },
        .{ .key = sc.a, .dx = -1, .dy = 0 },
        .{ .key = sc.d, .dx = 1, .dy = 0 },
    };

    for (move_pairs) |mp| {
        if (mp.key.isPressed(&state.input)) {
            // 尝试移动玩家
            if (try movePlayer(state, mp.dx, mp.dy)) {
                state.last_dir_x = mp.dx;
                state.last_dir_y = mp.dy;
                action_taken = true;
                break;
            }
        }
    }

    // 数字键 1：施放火球术
    if (sc._1.isPressed(&state.input)) {
        if (state.last_dir_x == 0 and state.last_dir_y == 0) {
            state.log("请先移动以确定火球方向", .{});
        } else {
            firemage_plugin.castFireball(
                &state.world,
                state.player_entity,
                state.last_dir_x,
                state.last_dir_y,
                25, // 基础伤害
            ) catch |err| {
                switch (err) {
                    error.NotEnoughMana => state.log("法力不足！", .{}),
                    else => state.log("施放火球术失败: {}", .{err}),
                }
            };
            action_taken = true;
        }
    }

    // 数字键 5 或空格：等待一回合
    if (sc._5.isPressed(&state.input) or sc.space.isPressed(&state.input)) {
        state.log("你等待了一回合...", .{});
        action_taken = true;
    }

    // ESC：退出
    if (sc.escape.isPressed(&state.input)) {
        state.input.quit = true;
    }

    return action_taken;
}

/// 移动玩家到相邻格子
fn movePlayer(state: *GameState, dx: i32, dy: i32) !bool {
    const player_pos = state.world.getComponent(state.player_entity, firemage_plugin.Position, firemage_plugin.COMP_POSITION).?;
    const nx = player_pos.x + dx;
    const ny = player_pos.y + dy;

    // 检查新位置是否有实体（敌人等）
    var blocked = false;
    var pos_storage = state.world.typedStorage(firemage_plugin.Position, firemage_plugin.COMP_POSITION);
    var pos_iter = pos_storage.iter();
    while (pos_iter.next()) |row| {
        if (row.component.x == nx and row.component.y == ny) {
            // 检查是否是玩家自己
            if (row.entity.eql(state.player_entity)) continue;

            // 检查是否是敌人（可以进行近战攻击）
            if (state.world.hasComponent(row.entity, firemage_plugin.Enemy, firemage_plugin.COMP_ENEMY)) {
                // 近战攻击！
                const atk_dmg: i32 = 8;
                if (state.world.getComponent(row.entity, firemage_plugin.Health, firemage_plugin.COMP_HEALTH)) |health| {
                    health.takeDamage(atk_dmg);
                    state.log("你攻击了敌人，造成 {} 点伤害！", .{atk_dmg});

                    // 发射伤害事件
                    state.world.emit(firemage_plugin.DamageEvent, .{
                        .target = row.entity,
                        .source = state.player_entity,
                        .amount = atk_dmg,
                        .damage_type = 0,
                    }) catch {};

                    // 检查敌人是否死亡
                    if (health.isDead()) {
                        state.log("敌人被击败了！", .{});
                        // 延迟销毁（通过 command buffer）
                        state.world.pending_commands.append(state.world.allocator, .{
                            .destroy_entity = row.entity,
                        }) catch {};
                    }
                }
                return true; // 攻击消耗回合
            }

            blocked = true;
            break;
        }
    }

    if (!blocked) {
        // 移动玩家
        player_pos.x = nx;
        player_pos.y = ny;
        return true;
    }

    return false;
}

// ============================================================================
// 渲染
// ============================================================================

/// 渲染整个游戏画面
fn renderGame(state: *GameState) !void {
    state.renderer.beginFrame();

    // 将摄像机对准玩家
    const pp = state.world.getComponent(state.player_entity, firemage_plugin.Position, firemage_plugin.COMP_POSITION).?;
    state.renderer.centerCamera(pp.x, pp.y);

    // 获取渲染范围（基于摄像机位置）
    const cam_x = state.renderer.camera_x;
    const cam_y = state.renderer.camera_y;
    const tw = state.renderer.tiles_wide;
    const th = state.renderer.tiles_high;

    // 1. 渲染地形
    for (0..@intCast(th)) |sy| {
        for (0..@intCast(tw)) |sx| {
            const wx = cam_x + @as(i32, @intCast(sx));
            const wy = cam_y + @as(i32, @intCast(sy));
            const terrain = state.map.getTerrain(wx, wy) catch .void;

            switch (terrain) {
                .wall => {
                    state.renderer.drawTile(wx, wy, renderer.Color.dark_grey);
                    state.renderer.drawChar(wx, wy, '#', renderer.Color.grey);
                },
                .floor => {
                    state.renderer.drawTile(wx, wy, renderer.Color{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 1.0 });
                    state.renderer.drawChar(wx, wy, '.', renderer.Color.dark_grey);
                },
                .stairs_up => {
                    state.renderer.drawChar(wx, wy, '<', renderer.Color.yellow);
                },
                .stairs_down => {
                    state.renderer.drawChar(wx, wy, '>', renderer.Color.yellow);
                },
                .door_closed => {
                    state.renderer.drawChar(wx, wy, '+', renderer.Color.orange);
                },
                .door_open => {
                    state.renderer.drawChar(wx, wy, '\'', renderer.Color.orange);
                },
                .shallow_water => {
                    state.renderer.drawTile(wx, wy, renderer.Color{ .r = 0.1, .g = 0.2, .b = 0.5, .a = 1.0 });
                    state.renderer.drawChar(wx, wy, '~', renderer.Color.blue);
                },
                .deep_water => {
                    state.renderer.drawTile(wx, wy, renderer.Color{ .r = 0.05, .g = 0.1, .b = 0.4, .a = 1.0 });
                },
                .void => {
                    state.renderer.drawTile(wx, wy, renderer.Color.black);
                },
            }
        }
    }

    // 2. 渲染实体（按位置查找，避免二次遍历地形）
    var pos_storage = state.world.typedStorage(firemage_plugin.Position, firemage_plugin.COMP_POSITION);
    var pos_iter = pos_storage.iter();
    while (pos_iter.next()) |row| {
        const wx = row.component.x;
        const wy = row.component.y;

        // 检查是否在屏幕范围内
        if (wx < cam_x - 1 or wx > cam_x + tw + 1) continue;
        if (wy < cam_y - 1 or wy > cam_y + th + 1) continue;

        // 获取渲染组件
        if (state.world.getComponent(row.entity, firemage_plugin.Renderable, firemage_plugin.COMP_RENDERABLE)) |rend| {
            const color = renderer.Color{ .r = rend.fg_r, .g = rend.fg_g, .b = rend.fg_b, .a = 1.0 };
            state.renderer.drawChar(wx, wy, rend.glyph, color);
        }
    }

    // 3. 渲染 UI 面板
    renderUI(state);

    state.renderer.endFrame();
}

/// 渲染 UI 信息面板
fn renderUI(state: *GameState) void {
    const r = &state.renderer;

    // 玩家状态
    if (state.world.getComponent(state.player_entity, firemage_plugin.Health, firemage_plugin.COMP_HEALTH)) |hp| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "HP: {}/{}", .{ hp.current, hp.max }) catch return;
        r.drawText(10, 610, text, renderer.Color.red);
    }

    if (state.world.getComponent(state.player_entity, firemage_plugin.Mana, firemage_plugin.COMP_MANA)) |mana| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "MP: {}/{}", .{ mana.current, mana.max }) catch return;
        r.drawText(10, 622, text, renderer.Color.blue);
    }

    // 游戏日志
    const log_y_start: i32 = 580;
    for (state.log_messages.items, 0..) |msg, i| {
        const y = log_y_start + @as(i32, @intCast(i)) * 14;
        r.drawText(200, y, msg[0..std.mem.indexOfScalar(u8, &msg, 0) orelse msg.len], renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8 });
    }

    // 控制提示
    r.drawText(10, 640, "WASD/方向键: 移动 | 1: 火球术 | 5/空格: 等待 | ESC: 退出", renderer.Color{ .r = 0.5, .g = 0.5, .b = 0.5 });
}

// ============================================================================
// 主函数
// ============================================================================

pub fn main() !void {
    // 使用通用目的分配器
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  T-Engine Zig — Tales of Maj'Eyal\n", .{});
    std.debug.print("  编译时插件数: {}\n", .{ALL_PLUGINS.len});
    std.debug.print("  系统调度表条目数: {}\n", .{system_table.entries.len});
    std.debug.print("========================================\n\n", .{});

    // 初始化游戏状态
    var state = try GameState.init(allocator);
    defer state.deinit();

    // 注册所有组件存储到世界
    try registerAllStorages(&state.world, allocator);

    // 主循环
    var running = true;
    while (running) {
        // 1. 处理输入
        renderer.pollInput(&state.input);
        if (state.input.quit) {
            running = false;
            break;
        }

        // 2. 处理玩家输入（回合制：等待玩家行动）
        const action_taken = try handlePlayerInput(&state);

        // 3. 如果玩家执行了动作，运行所有系统
        if (action_taken) {
            // 推进游戏时钟
            state.world.advanceTick();

            // 执行所有编译时注册的系统（按阶段顺序）
            try system_table.executeAll(&state.world);

            // 处理待执行命令（销毁实体等）
            state.world.processCommands();

            // 检查玩家是否死亡
            if (state.world.getComponent(state.player_entity, firemage_plugin.Health, firemage_plugin.COMP_HEALTH)) |hp| {
                if (hp.isDead()) {
                    state.log("你死了！按 ESC 退出...", .{});
                    state.waiting_for_input = false;
                }
            }
        }

        // 4. 渲染
        try renderGame(&state);

        // 5. 帧率控制
        state.renderer.delayMs(16); // ~60 FPS
    }
}

// ============================================================================
// 组件存储注册
// ============================================================================

/// 编译期生成所有组件存储的注册代码
/// 在实际项目中，这一步会由 comptime 代码自动完成
fn registerAllStorages(world: *ecs.World, allocator: std.mem.Allocator) !void {
    // 为每种组件类型创建存储并注册
    // 注意：这段代码应该由 comptime 自动生成，
    // 此处为了清晰展示而手动列出

    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Position));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Position).init(allocator);
        try world.registerStorage(firemage_plugin.Position, firemage_plugin.COMP_POSITION, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Health));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Health).init(allocator);
        try world.registerStorage(firemage_plugin.Health, firemage_plugin.COMP_HEALTH, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Mana));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Mana).init(allocator);
        try world.registerStorage(firemage_plugin.Mana, firemage_plugin.COMP_MANA, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.SpellPower));
        storage.* = try ecs.ComponentStorage(firemage_plugin.SpellPower).init(allocator);
        try world.registerStorage(firemage_plugin.SpellPower, firemage_plugin.COMP_SPELL_POWER, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Renderable));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Renderable).init(allocator);
        try world.registerStorage(firemage_plugin.Renderable, firemage_plugin.COMP_RENDERABLE, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Fireball));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Fireball).init(allocator);
        try world.registerStorage(firemage_plugin.Fireball, firemage_plugin.COMP_FIREBALL, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Burning));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Burning).init(allocator);
        try world.registerStorage(firemage_plugin.Burning, firemage_plugin.COMP_BURNING, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Player));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Player).init(allocator);
        try world.registerStorage(firemage_plugin.Player, firemage_plugin.COMP_PLAYER, storage);
    }
    {
        const storage = try allocator.create(ecs.ComponentStorage(firemage_plugin.Enemy));
        storage.* = try ecs.ComponentStorage(firemage_plugin.Enemy).init(allocator);
        try world.registerStorage(firemage_plugin.Enemy, firemage_plugin.COMP_ENEMY, storage);
    }
}
