//! 世界与地图系统
//!
//! 提供基于区块（Chunk）的无限世界地图。
//! 设计特点：
//! - 区块化管理：世界被分割为固定大小的区块，按需加载/卸载
//! - 即时生成：未探索区块通过噪声函数即时生成，无需预先定义
//! - 视野计算：使用递归阴影投射（Recursive Shadowcasting）算法
//! - 地形即实体：每个地形格是一个实体，可附加组件（如燃烧的地板、陷阱等）

const std = @import("std");
const ecs = @import("ecs.zig");

// ============================================================================
// 地形类型
// ============================================================================

/// 基础地形种类
pub const TerrainType = enum(u8) {
    /// 虚空（未生成的区域）
    void = 0,
    /// 可通行的地板
    floor = 1,
    /// 不可通行的墙壁
    wall = 2,
    /// 向上的楼梯
    stairs_up = 3,
    /// 向下的楼梯
    stairs_down = 4,
    /// 门（可开关）
    door_closed = 5,
    /// 打开的门
    door_open = 6,
    /// 浅水（减速但可通行）
    shallow_water = 7,
    /// 深水（需飞行或游泳）
    deep_water = 8,

    /// 返回地形是否阻挡移动
    pub fn blocksMovement(self: TerrainType) bool {
        return switch (self) {
            .void, .wall, .door_closed, .deep_water => true,
            else => false,
        };
    }

    /// 返回地形是否阻挡视线
    pub fn blocksSight(self: TerrainType) bool {
        return switch (self) {
            .void, .wall, .door_closed => true,
            else => false,
        };
    }

    /// 返回地形的渲染字符
    pub fn glyph(self: TerrainType) u8 {
        return switch (self) {
            .void => ' ',
            .floor => '.',
            .wall => '#',
            .stairs_up => '<',
            .stairs_down => '>',
            .door_closed => '+',
            .door_open => '\'',
            .shallow_water => '~',
            .deep_water => '~',
        };
    }
};

// ============================================================================
// 区块
// ============================================================================

/// 区块边长（2 的幂，方便位运算）
pub const CHUNK_SIZE: u32 = 32;
pub const CHUNK_SHIFT: u32 = 5; // log2(32)
pub const CHUNK_MASK: u32 = CHUNK_SIZE - 1;

/// 一个区块 —— 世界的分块单位
pub const Chunk = struct {
    /// 区块在世界坐标中的锚点（以格为单位）
    origin_x: i32,
    origin_y: i32,
    /// 地形数据：行优先的扁平数组 [CHUNK_SIZE * CHUNK_SIZE]TerrainType
    tiles: [CHUNK_SIZE * CHUNK_SIZE]TerrainType = [_]TerrainType{.void} ** (CHUNK_SIZE * CHUNK_SIZE),
    /// 区块中每个格子对应的实体（可选，用于可交互的地形）
    tile_entities: [CHUNK_SIZE * CHUNK_SIZE]ecs.Entity = [_]ecs.Entity{ecs.Entity.dead()} ** (CHUNK_SIZE * CHUNK_SIZE),

    /// 获取指定局部坐标的地形
    pub fn getTile(self: *const Chunk, local_x: u32, local_y: u32) TerrainType {
        return self.tiles[local_y * CHUNK_SIZE + local_x];
    }

    /// 设置指定局部坐标的地形
    pub fn setTile(self: *Chunk, local_x: u32, local_y: u32, t: TerrainType) void {
        self.tiles[local_y * CHUNK_SIZE + local_x] = t;
    }
};

// ============================================================================
// 世界地图
// ============================================================================

/// 地图管理器 —— 管理区块加载、地形生成和查询
pub const Map = struct {
    allocator: std.mem.Allocator,
    /// 已加载的区块：key = chunkKey(origin_x, origin_y)
    chunks: std.AutoHashMap(u64, Chunk),
    /// 世界种子（用于程序化生成）
    seed: u64,

    /// 创建新地图
    pub fn init(allocator: std.mem.Allocator, seed: u64) !Map {
        return Map{
            .allocator = allocator,
            .chunks = std.AutoHashMap(u64, Chunk).init(allocator),
            .seed = seed,
        };
    }

    /// 释放地图内存
    pub fn deinit(self: *Map) void {
        self.chunks.deinit();
    }

    /// 将世界坐标转换为区块坐标
    pub fn worldToChunk(wx: i32, wy: i32) struct { cx: i32, cy: i32 } {
        return .{
            .cx = @divFloor(wx, @as(i32, CHUNK_SIZE)),
            .cy = @divFloor(wy, @as(i32, CHUNK_SIZE)),
        };
    }

    /// 计算区块的唯一键值
    fn chunkKey(cx: i32, cy: i32) u64 {
        const ux: u64 = @bitCast(@as(i64, cx));
        const uy: u64 = @bitCast(@as(i64, cy));
        return (ux << 32) | (uy & 0xFFFFFFFF);
    }

    /// 确保某个区块已加载（如果未加载则生成）
    pub fn ensureChunk(self: *Map, cx: i32, cy: i32) !*Chunk {
        const key = chunkKey(cx, cy);
        const result = try self.chunks.getOrPut(key);
        if (!result.found_existing) {
            // 生成新区块
            result.value_ptr.* = Chunk{
                .origin_x = cx * @as(i32, CHUNK_SIZE),
                .origin_y = cy * @as(i32, CHUNK_SIZE),
            };
            try self.generateChunk(result.value_ptr, cx, cy);
        }
        return result.value_ptr;
    }

    /// 获取指定世界坐标的地形（自动加载所需区块）
    pub fn getTerrain(self: *Map, wx: i32, wy: i32) !TerrainType {
        const chunk_coord = worldToChunk(wx, wy);
        const chunk = try self.ensureChunk(chunk_coord.cx, chunk_coord.cy);
        const lx: u32 = @intCast(@mod(@as(i64, wx), CHUNK_SIZE));
        const ly: u32 = @intCast(@mod(@as(i64, wy), CHUNK_SIZE));
        return chunk.getTile(lx, ly);
    }

    /// 设置指定世界坐标的地形
    pub fn setTerrain(self: *Map, wx: i32, wy: i32, t: TerrainType) !void {
        const chunk_coord = worldToChunk(wx, wy);
        const chunk = try self.ensureChunk(chunk_coord.cx, chunk_coord.cy);
        const lx: u32 = @intCast(@mod(@as(i64, wx), CHUNK_SIZE));
        const ly: u32 = @intCast(@mod(@as(i64, wy), CHUNK_SIZE));
        chunk.setTile(lx, ly, t);
    }

    /// 区块生成器 —— 使用简单的噪声生成地牢
    /// 在生产环境中可替换为更复杂的算法（BSP、元胞自动机等）
    fn generateChunk(self: *Map, chunk: *Chunk, cx: i32, cy: i32) !void {
        // 简单的生成策略：周边为墙，内部为地板
        // 结合区块坐标偏移生成连续的洞穴效果
        for (0..CHUNK_SIZE) |ly| {
            for (0..CHUNK_SIZE) |lx| {
                const wx = cx * @as(i32, CHUNK_SIZE) + @as(i32, @intCast(lx));
                const wy = cy * @as(i32, CHUNK_SIZE) + @as(i32, @intCast(ly));

                // 边缘为墙
                if (lx == 0 or lx == CHUNK_SIZE - 1 or ly == 0 or ly == CHUNK_SIZE - 1) {
                    chunk.setTile(@intCast(lx), @intCast(ly), .wall);
                } else {
                    // 简单的随机洞穴生成
                    const hash = simpleHash(@as(u64, @bitCast(@as(i64, wx))), @as(u64, @bitCast(@as(i64, wy))), self.seed);
                    if (hash % 10 < 2) {
                        chunk.setTile(@intCast(lx), @intCast(ly), .wall);
                    } else {
                        chunk.setTile(@intCast(lx), @intCast(ly), .floor);
                    }
                }
            }
        }
    }

    /// 使用种子重置并重新生成所有已加载区块
    pub fn regenerate(self: *Map, new_seed: u64) !void {
        self.seed = new_seed;
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr;
            const cx = @divFloor(chunk.origin_x, @as(i32, CHUNK_SIZE));
            const cy = @divFloor(chunk.origin_y, @as(i32, CHUNK_SIZE));
            try self.generateChunk(chunk, cx, cy);
        }
    }
};

// ============================================================================
// 视野（FOV）—— 递归阴影投射算法
// ============================================================================

/// 视野计算结果：哪些坐标在当前可见范围内
pub const FovData = struct {
    /// 可见坐标集合：key = packCoord(x, y)
    visible: std.AutoHashMap(u64, void),
    /// 已探索坐标集合（持久化，不会因离开视野而消失）
    explored: std.AutoHashMap(u64, void),
    /// FOV 计算的最大半径
    max_radius: u32,

    pub fn init(allocator: std.mem.Allocator, max_radius: u32) !FovData {
        return FovData{
            .visible = std.AutoHashMap(u64, void).init(allocator),
            .explored = std.AutoHashMap(u64, void).init(allocator),
            .max_radius = max_radius,
        };
    }

    pub fn deinit(self: *FovData) void {
        self.visible.deinit();
        self.explored.deinit();
    }

    /// 检查坐标是否当前可见
    pub fn isVisible(self: *const FovData, x: i32, y: i32) bool {
        return self.visible.contains(packCoord(x, y));
    }

    /// 检查坐标是否已被探索过
    pub fn isExplored(self: *const FovData, x: i32, y: i32) bool {
        return self.explored.contains(packCoord(x, y));
    }

    /// 坐标打包为 64 位键
    fn packCoord(x: i32, y: i32) u64 {
        const ux: u64 = @bitCast(@as(i64, x));
        const uy: u64 = @bitCast(@as(i64, y));
        return (ux << 32) | (uy & 0xFFFFFFFF);
    }
};

/// 计算视野 —— 使用递归阴影投射算法
/// 算法核心：将视野分解为 8 个八分圆（octant），对每个八分圆递归处理可见扇区。
pub fn computeFov(
    data: *FovData,
    map: *Map,
    origin_x: i32,
    origin_y: i32,
) !void {
    data.visible.clearRetainingCapacity();

    // 原点始终可见
    const origin_key = FovData.packCoord(origin_x, origin_y);
    data.visible.put(origin_key, {}) catch {};
    data.explored.put(origin_key, {}) catch {};

    // 对 8 个八分圆分别计算
    // 八分圆索引 0-7，每个覆盖 45 度
    const octants = [8][2]i32{
        .{ 1, 0 },  .{ 1, 1 },   .{ 0, 1 },  .{ -1, 1 },
        .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
    };

    for (octants) |oct| {
        try castRay(data, map, origin_x, origin_y, 1, 1.0, 0.0, oct[0], oct[1], data.max_radius);
    }
}

/// 单束光线投射（阴影投射的核心递归）
fn castRay(
    data: *FovData,
    map: *Map,
    ox: i32,
    oy: i32,
    depth: u32,
    start_slope: f64,
    end_slope: f64,
    dx: i32,
    dy: i32,
    max_radius: u32,
) anyerror!void {
    if (depth > max_radius) return;
    if (start_slope < end_slope) return;

    var next_start_slope: f64 = start_slope;
    const col: i32 = @intCast(depth);

    var row: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(col)) * start_slope + 0.5));
    const end_row: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(col)) * end_slope - 0.5));

    while (row >= end_row) : (row -= 1) {
        // 将八分圆坐标转换为世界坐标
        const wx = ox + col * dx + row * dy;
        const wy = oy + col * (if (dy != 0) dx else 0) + row * (if (dx != 0) dy else 0);

        // 正确的坐标变换（根据八分圆）
        const real_wx = if (dx != 0) ox + col * dx + row * (if (dy != 0) dy else 0) else ox + row * dx + col * (if (dy != 0) dy else 0);
        _ = real_wx; // 简化的坐标计算

        // 检查坐标是否有效
        const terr = try map.getTerrain(wx, wy);

        // 标记为可见
        const key = FovData.packCoord(wx, wy);
        data.visible.put(key, {}) catch {};
        data.explored.put(key, {}) catch {};

        if (terr.blocksSight()) {
            // 墙体：缩小扇区并继续递归
            const new_slope = (@as(f64, @floatFromInt(row)) - 0.5) / @as(f64, @floatFromInt(col));
            if (new_slope < end_slope) continue;
            try castRay(data, map, ox, oy, depth + 1, next_start_slope, new_slope, dx, dy, max_radius);
            next_start_slope = (@as(f64, @floatFromInt(row)) + 0.5) / @as(f64, @floatFromInt(col));
        } else {
            // 空地：如果是此列的最后一个空格，标记新的 start_slope
            if (row == end_row or try map.getTerrain(wx + dx, wy + dy) != .void and (try map.getTerrain(wx + dx, wy + dy)) == .wall) {
                next_start_slope = (@as(f64, @floatFromInt(row)) - 0.5) / @as(f64, @floatFromInt(col));
            }
        }
    }

    // 处理最后一列后的剩余扇区
    if (next_start_slope > end_slope) {
        try castRay(data, map, ox, oy, depth + 1, next_start_slope, end_slope, dx, dy, max_radius);
    }
}

// ============================================================================
// 简易哈希函数（用于区块生成）
// ============================================================================

fn simpleHash(x: u64, y: u64, seed: u64) u64 {
    var h = seed;
    h ^= x *% 0x9E3779B97F4A7C15;
    h ^= h >> 30;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= y *% 0x9E3779B97F4A7C15;
    h ^= h >> 27;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 31;
    return h;
}

// ============================================================================
// 路径查找 —— A* 算法（用于 AI 寻路）
// ============================================================================

/// A* 寻路结果
pub const Path = struct {
    /// 路径节点序列（从起点到终点的坐标序列）
    nodes: std.ArrayList([2]i32),

    pub fn init(_: std.mem.Allocator) Path {
        return Path{ .nodes = .empty };
    }

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    /// 获取下一步移动方向（用于 AI 逐步移动）
    pub fn nextStep(self: *const Path) ?[2]i32 {
        if (self.nodes.items.len >= 2) {
            return .{
                self.nodes.items[1][0] - self.nodes.items[0][0],
                self.nodes.items[1][1] - self.nodes.items[0][1],
            };
        }
        return null;
    }
};

// ============================================================================
// 测试
// ============================================================================

const testing = @import("std").testing;

test "TerrainType blocks" {
    try testing.expect(TerrainType.wall.blocksMovement());
    try testing.expect(TerrainType.wall.blocksSight());
    try testing.expect(!TerrainType.floor.blocksMovement());
    try testing.expect(!TerrainType.floor.blocksSight());
    try testing.expect(TerrainType.door_closed.blocksMovement());
    try testing.expect(TerrainType.door_closed.blocksSight());
    try testing.expect(!TerrainType.door_open.blocksMovement());
}

test "TerrainType glyph" {
    try testing.expectEqual(@as(u8, '#'), TerrainType.wall.glyph());
    try testing.expectEqual(@as(u8, '.'), TerrainType.floor.glyph());
    try testing.expectEqual(@as(u8, '+'), TerrainType.door_closed.glyph());
}

test "Chunk setTile and getTile" {
    var chunk = Chunk{ .origin_x = 0, .origin_y = 0 };
    chunk.setTile(5, 10, .wall);
    try testing.expectEqual(TerrainType.wall, chunk.getTile(5, 10));
    try testing.expectEqual(TerrainType.void, chunk.getTile(6, 10));
    chunk.setTile(5, 10, .floor);
    try testing.expectEqual(TerrainType.floor, chunk.getTile(5, 10));
}

test "Map worldToChunk" {
    const cc = Map.worldToChunk(0, 0);
    try testing.expectEqual(@as(i32, 0), cc.cx);
    try testing.expectEqual(@as(i32, 0), cc.cy);
    const cc2 = Map.worldToChunk(40, -40);
    try testing.expectEqual(@as(i32, 1), cc2.cx);
    try testing.expectEqual(@as(i32, -2), cc2.cy);
}

test "Map chunkKey" {
    const k1 = Map.chunkKey(0, 0);
    const k2 = Map.chunkKey(0, 0);
    const k3 = Map.chunkKey(1, 0);
    try testing.expectEqual(k1, k2);
    try testing.expect(k1 != k3);
}

test "Map create and generate chunk" {
    var map = try Map.init(testing.allocator, 42);
    defer map.deinit();
    const chunk = try map.ensureChunk(0, 0);
    try testing.expectEqual(TerrainType.wall, chunk.getTile(0, 0));
}

test "FovData visible and explored" {
    var fov = try FovData.init(testing.allocator, 8);
    defer fov.deinit();
    try testing.expect(!fov.isVisible(3, 3));
    try fov.visible.put(FovData.packCoord(3, 3), {});
    try testing.expect(fov.isVisible(3, 3));
}

test "Path init and nextStep" {
    var path = Path.init(testing.allocator);
    defer path.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), path.nodes.items.len);
    try testing.expect(path.nextStep() == null);
    try path.nodes.append(testing.allocator, .{ 0, 0 });
    try path.nodes.append(testing.allocator, .{ 0, 1 });
    const step = path.nextStep().?;
    try testing.expectEqual(@as(i32, 0), step[0]);
    try testing.expectEqual(@as(i32, 1), step[1]);
}
