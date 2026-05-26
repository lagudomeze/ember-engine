//! T-Engine Zig —— ECS 核心模块
//!
//! 设计哲学：编译期确定所有组件类型，运行时零虚表查找。
//! 使用稀疏集合（Sparse Set）存储组件，保证 O(1) 随机访问和缓存友好的遍历。
//!
//! 核心概念：
//! - Entity: 64 位句柄，含世代号，防止悬空引用（ABA 问题）
//! - Component: 纯数据 struct，通过 comptime 注册获得唯一 TypeId
//! - System: 操作组件数据的函数，由调度器按依赖顺序执行
//! - Event: 系统间松耦合通信的消息载体
//! - World: 实体、组件、事件的总容器

const std = @import("std");
const testing = std.testing;

// ============================================================================
// 实体定义
// ============================================================================

/// 实体句柄 —— 64 位 packed struct，零额外内存开销。
/// generation 字段解决 ABA 问题：复用已删除实体时，generation 递增，
/// 旧句柄自动失效。
pub const Entity = packed struct(u64) {
    /// 世代号，每次复用此槽位时递增
    generation: u32,
    /// 在实体数组中的槽位索引
    index: u32,

    /// 返回一个无效实体，用于表示"无实体"
    pub fn dead() Entity {
        return .{ .index = 0, .generation = 0 };
    }

    /// 判断实体是否存活（generation 不为 0 表示有效）
    pub fn isAlive(self: Entity) bool {
        return self.generation != 0;
    }

    pub fn eql(self: Entity, other: Entity) bool {
        return @as(u64, @bitCast(self)) == @as(u64, @bitCast(other));
    }

    /// 为 AutoHashMap 提供 hash 上下文
    pub const HashContext = struct {
        pub fn hash(_: @This(), e: Entity) u64 {
            const val: u64 = @bitCast(e);
            return val *% 0x9E3779B97F4A7C15;
        }
        pub fn eql(_: @This(), a: Entity, b: Entity) bool {
            return a.eql(b);
        }
    };
};

// ============================================================================
// 组件类型 ID 注册 —— 编译期分配唯一 ID
// ============================================================================

/// 全局组件类型计数器，编译期递增
var comptime_component_id: u16 = 0;

/// 注册一个组件类型，返回唯一的运行时 ID。
/// 必须在编译期调用，确保 ID 确定性。
pub fn registerComponent(comptime name: []const u8) u16 {
    _ = name;
    const id = comptime_component_id;
    comptime_component_id += 1;
    return id;
}

/// 获取已注册的组件类型总数
pub fn componentTypeCount() u16 {
    return comptime_component_id;
}

// ============================================================================
// 单组件稀疏集合存储
// ============================================================================

/// 为特定组件类型 T 生成的稀疏集合存储。
/// - sparse: 实体 index → dense 数组中的位置（INVALID 表示无此组件）
/// - dense:  紧凑数组，按插入顺序存储实体
/// - data:   紧凑数组，按插入顺序存储组件数据
///
/// 插入 O(1)，删除 O(1)（swap-remove），遍历 O(n)。
/// 最大实体数量受限于 dense 数组的容量，可动态增长。
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        const INVALID: u32 = std.math.maxInt(u32);

        /// 稀疏映射：实体索引 → 稠密数组位置
        sparse: std.ArrayList(u32) = .empty,
        /// 稠密实体数组，与 data 一一对应
        entities: std.ArrayList(Entity) = .empty,
        /// 组件数据数组，与 entities 一一对应
        data: std.ArrayList(T) = .empty,

        /// 初始化空的组件存储
        pub fn init(_: std.mem.Allocator) !Self {
            return Self{
                .sparse = .empty,
                .entities = .empty,
                .data = .empty,
            };
        }

        /// 释放所有内存
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.sparse.deinit(allocator);
            self.entities.deinit(allocator);
            self.data.deinit(allocator);
        }

        /// 确保稀疏数组足够大，能容纳给定实体索引
        fn ensureSparse(self: *Self, allocator: std.mem.Allocator, entity_index: u32) !void {
            if (entity_index >= self.sparse.items.len) {
                const old_len = self.sparse.items.len;
                const new_len = entity_index + 1;
                try self.sparse.resize(allocator, new_len);
                // 将新扩容的部分填充为 INVALID（resize 不初始化新元素）
                @memset(self.sparse.items[old_len..new_len], INVALID);
            }
        }

        /// 为实体插入或覆盖组件
        pub fn insert(self: *Self, allocator: std.mem.Allocator, entity: Entity, value: T) !void {
            try self.ensureSparse(allocator, entity.index);

            const dense_idx = self.sparse.items[entity.index];
            if (dense_idx == INVALID) {
                // 新组件：追加到末尾
                const new_idx: u32 = @intCast(self.entities.items.len);
                try self.entities.append(allocator, entity);
                try self.data.append(allocator, value);
                self.sparse.items[entity.index] = new_idx;
            } else {
                // 已有组件：原地覆盖
                self.data.items[dense_idx] = value;
            }
        }

        /// 移除实体的组件（swap-remove）
        pub fn remove(self: *Self, _: std.mem.Allocator, entity: Entity) void {
            if (entity.index >= self.sparse.items.len) return;
            const dense_idx = self.sparse.items[entity.index];
            if (dense_idx == INVALID) return;

            const last_idx: u32 = @intCast(self.entities.items.len - 1);
            if (dense_idx != last_idx) {
                // swap-remove：将最后一个元素移到被删除位置
                const last_entity = self.entities.items[last_idx];
                self.entities.items[dense_idx] = last_entity;
                self.data.items[dense_idx] = self.data.items[last_idx];
                // 更新被移动实体的稀疏映射
                if (last_entity.index < self.sparse.items.len) {
                    self.sparse.items[last_entity.index] = dense_idx;
                }
            }
            self.entities.items.len -= 1;
            self.data.items.len -= 1;

            self.sparse.items[entity.index] = INVALID;
        }

        /// 获取实体的组件指针（可变）
        pub fn get(self: *Self, entity: Entity) ?*T {
            if (entity.index >= self.sparse.items.len) return null;
            const dense_idx = self.sparse.items[entity.index];
            if (dense_idx == INVALID) return null;
            return &self.data.items[dense_idx];
        }

        /// 获取实体的组件指针（只读）
        pub fn getConst(self: *const Self, entity: Entity) ?*const T {
            if (entity.index >= self.sparse.items.len) return null;
            const dense_idx = self.sparse.items[entity.index];
            if (dense_idx == INVALID) return null;
            return &self.data.items[dense_idx];
        }

        /// 检查实体是否拥有此组件
        pub fn has(self: *const Self, entity: Entity) bool {
            if (entity.index >= self.sparse.items.len) return false;
            return self.sparse.items[entity.index] != INVALID;
        }

        /// 返回当前持有此组件的实体数量
        pub fn count(self: *const Self) usize {
            return self.entities.items.len;
        }

        /// 获取第 i 个实体的组件（用于遍历）
        pub fn getAt(self: *Self, i: usize) *T {
            return &self.data.items[i];
        }

        /// 获取第 i 个实体（用于遍历）
        pub fn entityAt(self: *const Self, i: usize) Entity {
            return self.entities.items[i];
        }

        /// 遍历：同时获取实体和可变组件引用
        pub fn iter(self: *Self) Iterator {
            return .{ .storage = self, .index = 0 };
        }

        pub const Iterator = struct {
            storage: *Self,
            index: usize,

            pub const Entry = struct {
                entity: Entity,
                component: *T,
            };

            pub fn next(self: *Iterator) ?Entry {
                if (self.index >= self.storage.entities.items.len) return null;
                defer self.index += 1;
                return Entry{
                    .entity = self.storage.entities.items[self.index],
                    .component = &self.storage.data.items[self.index],
                };
            }
        };
    };
}

// ============================================================================
// 事件系统
// ============================================================================

/// 事件类型 ID —— 编译期分配
var comptime_event_id: u16 = 0;

/// 注册事件类型，返回唯一 ID
pub fn registerEvent(comptime name: []const u8) u16 {
    _ = name;
    const id = comptime_event_id;
    comptime_event_id += 1;
    return id;
}

// ============================================================================
// 世界 —— ECS 的中央调度中心
// ============================================================================

/// 世界容纳所有实体、组件存储和事件队列。
///
/// 设计要点：
/// - 所有内存操作通过显式传入的 allocator 执行
/// - 实体生成/销毁是 O(1) 操作（使用空闲链表复用槽位）
/// - 事件队列每帧处理一次，先收集再分发
pub const World = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// 全局时钟，每帧递增
    tick: u64,

    /// 实体数组：index → Entity（generation 字段用于验证有效性）
    entity_generations: std.ArrayList(u32) = .empty,
    /// 空闲实体槽位链表（存储可复用的 index）
    free_entities: std.ArrayList(u32) = .empty,

    /// 组件存储映射：type_id → 类型擦除的存储指针
    storages: std.AutoArrayHashMapUnmanaged(u16, *anyopaque) = .empty,

    /// 事件队列：每帧收集，帧末分发
    event_queue: std.ArrayList(ErasedEvent) = .empty,

    /// 待处理的命令
    pending_commands: std.ArrayList(Command) = .empty,

    /// 类型擦除的事件
    pub const ErasedEvent = struct {
        type_id: u16,
        /// 指向堆上分配的事件数据的指针
        data: *anyopaque,
        /// 释放函数
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    /// 延迟执行的命令
    pub const Command = union(enum) {
        destroy_entity: Entity,
    };

    /// 创建新的空世界
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .tick = 0,
            .entity_generations = .empty,
            .free_entities = .empty,
            .storages = .empty,
            .event_queue = .empty,
            .pending_commands = .empty,
        };
    }

    /// 释放世界中的所有资源
    pub fn deinit(self: *Self) void {
        for (self.event_queue.items) |ev| {
            ev.destroy(ev.data, self.allocator);
        }
        self.event_queue.deinit(self.allocator);

        self.storages.deinit(self.allocator);

        self.entity_generations.deinit(self.allocator);
        self.free_entities.deinit(self.allocator);
        self.pending_commands.deinit(self.allocator);
    }

    /// 创建一个新实体，返回有效句柄。
    /// 优先复用已删除实体的槽位（O(1)），否则追加新槽位。
    pub fn createEntity(self: *Self) !Entity {
        if (self.free_entities.items.len > 0) {
            const index = self.free_entities.items[self.free_entities.items.len - 1];
            self.free_entities.items.len -= 1;
            const gen = self.entity_generations.items[index];
            return Entity{ .index = index, .generation = gen };
        } else {
            const index: u32 = @intCast(self.entity_generations.items.len);
            const gen: u32 = 1; // 第一代
            try self.entity_generations.append(self.allocator, gen);
            return Entity{ .index = index, .generation = gen };
        }
    }

    /// 销毁实体，递增其世代号，将槽位加入空闲链表。
    pub fn destroyEntity(self: *Self, entity: Entity) void {
        if (!self.isAlive(entity)) return;
        self.entity_generations.items[entity.index] += 1;
        self.free_entities.append(self.allocator, entity.index) catch {};
    }

    /// 检查实体是否有效
    pub fn isAlive(self: *const Self, entity: Entity) bool {
        if (entity.index >= self.entity_generations.items.len) return false;
        return self.entity_generations.items[entity.index] == entity.generation;
    }

    /// 注册组件存储 —— 必须在添加组件之前调用
    pub fn registerStorage(self: *Self, comptime T: type, type_id: u16, storage: *ComponentStorage(T)) !void {
        try self.storages.put(self.allocator, type_id, @ptrCast(storage));
    }

    /// 获取带类型的组件存储指针
    pub fn typedStorage(self: *Self, comptime T: type, type_id: u16) *ComponentStorage(T) {
        const ptr = self.storages.get(type_id) orelse @panic("组件存储未注册");
        return @ptrCast(@alignCast(ptr));
    }

    /// 为实体添加组件（通过类型 ID 查找对应存储）
    pub fn addComponent(self: *Self, entity: Entity, comptime T: type, type_id: u16, value: T) !void {
        const storage = self.typedStorage(T, type_id);
        try storage.insert(self.allocator, entity, value);
    }

    /// 移除实体的组件
    pub fn removeComponent(self: *Self, entity: Entity, comptime T: type, type_id: u16) void {
        const storage = self.typedStorage(T, type_id);
        storage.remove(self.allocator, entity);
    }

    /// 获取实体的组件（可变引用）
    pub fn getComponent(self: *Self, entity: Entity, comptime T: type, type_id: u16) ?*T {
        const storage = self.typedStorage(T, type_id);
        return storage.get(entity);
    }

    /// 检查实体是否拥有某组件
    pub fn hasComponent(self: *Self, entity: Entity, comptime T: type, type_id: u16) bool {
        const storage = self.typedStorage(T, type_id);
        return storage.has(entity);
    }

    /// 发射事件到队列中（帧末统一处理）
    pub fn emit(self: *Self, comptime T: type, event: T) !void {
        const type_id = T.event_type_id;
        const heap_data = try self.allocator.create(T);
        heap_data.* = event;
        try self.event_queue.append(self.allocator, .{
            .type_id = type_id,
            .data = @ptrCast(heap_data),
            .destroy = eraseDestroy(T),
        });
    }

    /// 类型擦除的析构函数生成器
    fn eraseDestroy(comptime T: type) *const fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                alloc.destroy(typed);
            }
        }.destroy;
    }

    /// 处理所有待执行的命令（销毁实体等）
    pub fn processCommands(self: *Self) void {
        for (self.pending_commands.items) |cmd| {
            switch (cmd) {
                .destroy_entity => |entity| {
                    self.destroyEntity(entity);
                },
            }
        }
        self.pending_commands.clearRetainingCapacity();
    }

    /// 推进游戏时钟
    pub fn advanceTick(self: *Self) void {
        self.tick += 1;
    }
};

// ============================================================================
// 查询迭代器 —— 编译期确定组件组合
// ============================================================================

/// 查询一组组件的实体迭代器。
/// 使用最小计数组件策略：在请求的组件中，选择实体数最少的组件作为驱动，
/// 减少无用遍历。
///
/// 用法：
///   var q = world.query(.{Position, Health}, .{pos_id, health_id});
///   while (q.next()) |row| { ... }
pub fn Query(comptime Components: type) type {
    const component_count = @typeInfo(Components).@"struct".fields.len;

    return struct {
        const Self = @This();

        world: *World,
        type_ids: [component_count]u16,
        /// 驱动组件的索引（最小计数组件）
        driver_idx: usize,

        /// 遍历游标
        cursor: usize,
        len: usize,

        pub fn init(world: *World, type_ids: [component_count]u16) Self {
            // 找出实体数最少的组件作为驱动
            var min_count: usize = std.math.maxInt(usize);
            var min_idx: usize = 0;
            inline for (type_ids, 0..) |tid, i| {
                const storage_ptr = world.storages.get(tid) orelse continue;
                // 通过类型擦除访问计数（使用 vtable）
                const count = @as(*ComponentStorage(u8), @ptrCast(@alignCast(storage_ptr))).count();
                if (count < min_count) {
                    min_count = count;
                    min_idx = i;
                }
            }

            return Self{
                .world = world,
                .type_ids = type_ids,
                .driver_idx = min_idx,
                .cursor = 0,
                .len = min_count,
            };
        }

        /// 返回下一个匹配的实体及其组件引用
        /// 对每行数据需要手动获取对应组件
        pub fn nextRaw(self: *Self) ?Entity {
            while (self.cursor < self.len) {
                // 获取驱动存储中第 cursor 个实体
                const driver_tid = self.type_ids[self.driver_idx];
                const driver_storage = self.world.storages.get(driver_tid).?;
                const driver = @as(*ComponentStorage(u8), @ptrCast(@alignCast(driver_storage)));
                const entity = driver.entityAt(self.cursor);
                self.cursor += 1;

                // 检查实体是否拥有所有其他请求的组件
                var has_all = true;
                inline for (self.type_ids, 0..) |tid, i| {
                    if (i == self.driver_idx) continue;
                    const storage_ptr = self.world.storages.get(tid) orelse {
                        has_all = false;
                        break;
                    };
                    const storage = @as(*ComponentStorage(u8), @ptrCast(@alignCast(storage_ptr)));
                    if (!storage.has(entity)) {
                        has_all = false;
                        break;
                    }
                }
                if (has_all) return entity;
            }
            return null;
        }
    };
}

// ============================================================================
// 测试
// ============================================================================

test "Entity create and destroy" {
    var world = try World.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.createEntity();
    try testing.expect(world.isAlive(e1));

    const e2 = try world.createEntity();
    try testing.expect(world.isAlive(e2));

    world.destroyEntity(e1);
    try testing.expect(!world.isAlive(e1));

    // 复用 e1 的槽位
    const e3 = try world.createEntity();
    try testing.expect(e3.index == e1.index);
    try testing.expect(e3.generation == e1.generation + 1);
}

test "ComponentStorage insert and get" {
    const Pos = struct { x: i32, y: i32 };
    var storage = try ComponentStorage(Pos).init(testing.allocator);
    defer storage.deinit(testing.allocator);

    const e = Entity{ .index = 0, .generation = 1 };
    try storage.insert(testing.allocator, e, .{ .x = 5, .y = 10 });

    const pos = storage.get(e).?;
    try testing.expect(pos.x == 5);
    try testing.expect(pos.y == 10);
}

test "ComponentStorage remove" {
    const Pos = struct { x: i32, y: i32 };
    var storage = try ComponentStorage(Pos).init(testing.allocator);
    defer storage.deinit(testing.allocator);

    const e1 = Entity{ .index = 0, .generation = 1 };
    const e2 = Entity{ .index = 1, .generation = 1 };
    try storage.insert(testing.allocator, e1, .{ .x = 1, .y = 2 });
    try storage.insert(testing.allocator, e2, .{ .x = 3, .y = 4 });

    storage.remove(testing.allocator, e1);
    try testing.expect(storage.get(e1) == null);
    try testing.expect(storage.get(e2) != null);
    try testing.expect(storage.count() == 1);
}

test "ComponentStorage has check" {
    const Pos = struct { x: i32, y: i32 };
    var storage = try ComponentStorage(Pos).init(testing.allocator);
    defer storage.deinit(testing.allocator);

    const e = Entity{ .index = 0, .generation = 1 };
    try testing.expect(!storage.has(e));
    try storage.insert(testing.allocator, e, .{ .x = 5, .y = 5 });
    try testing.expect(storage.has(e));
}

test "ComponentStorage iteration" {
    const Pos = struct { x: i32, y: i32 };
    var storage = try ComponentStorage(Pos).init(testing.allocator);
    defer storage.deinit(testing.allocator);

    try storage.insert(testing.allocator, Entity{ .index = 0, .generation = 1 }, .{ .x = 1, .y = 2 });
    try storage.insert(testing.allocator, Entity{ .index = 1, .generation = 1 }, .{ .x = 3, .y = 4 });

    var count: usize = 0;
    var iter = storage.iter();
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "ComponentStorage replace existing" {
    const Pos = struct { x: i32, y: i32 };
    var storage = try ComponentStorage(Pos).init(testing.allocator);
    defer storage.deinit(testing.allocator);

    const e = Entity{ .index = 0, .generation = 1 };
    try storage.insert(testing.allocator, e, .{ .x = 1, .y = 2 });
    try storage.insert(testing.allocator, e, .{ .x = 99, .y = 88 });
    try testing.expectEqual(@as(i32, 99), storage.get(e).?.x);
    try testing.expectEqual(@as(i32, 88), storage.get(e).?.y);
    try testing.expect(storage.count() == 1); // 不变
}

test "World reuse entity slot" {
    var world = try World.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.createEntity();
    world.destroyEntity(e1);
    const e2 = try world.createEntity();
    try testing.expectEqual(e1.index, e2.index);
    try testing.expect(e2.generation == e1.generation + 1);
}

test "World isAlive check" {
    var world = try World.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try testing.expect(world.isAlive(e));
    try testing.expect(!world.isAlive(Entity.dead()));
}

test "World emit and process events" {
    var world = try World.init(testing.allocator);
    defer world.deinit();

    const TestEvent = struct {
        value: i32,
        pub const event_type_id: u16 = 0;
    };

    try world.emit(TestEvent, .{ .value = 42 });
    try testing.expect(world.event_queue.items.len == 1);
    try testing.expect(world.event_queue.items[0].type_id == 0);
}

test "World command destroy entity" {
    var world = try World.init(testing.allocator);
    defer world.deinit();

    const e = try world.createEntity();
    try world.pending_commands.append(testing.allocator, .{ .destroy_entity = e });
    world.processCommands();
    try testing.expect(!world.isAlive(e));
}
