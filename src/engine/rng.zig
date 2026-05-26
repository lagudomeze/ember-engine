//! 伪随机数生成器 —— Xoshiro256** 算法
//!
//! Xoshiro256** 是目前最快的统计质量最高的 PRNG 之一。
//! 比原 ToME4 使用的 SFMT Mersenne Twister 更快，状态更小（256bit vs 2.5KB）。
//!
//! 特性：
//! - 确定性种子：相同种子产生相同序列，支持录像回放
//! - 范围随机：整数范围、浮点数、正态分布
//! - 集合操作：随机选取、洗牌

const std = @import("std");

/// Xoshiro256** 伪随机数生成器
/// 状态：4 个 u64，共 256 位
pub const RNG = struct {
    s: [4]u64,

    /// 用种子创建
    pub fn init(seed: u64) RNG {
        var r = RNG{ .s = undefined };
        // 使用 SplitMix64 从种子初始化状态
        var z = seed;
        r.s[0] = splitMix64(&z);
        r.s[1] = splitMix64(&z);
        r.s[2] = splitMix64(&z);
        r.s[3] = splitMix64(&z);
        return r;
    }

    /// 从多个种子创建（例如 tick + entity_id）
    pub fn initMulti(seeds: []const u64) RNG {
        var combined: u64 = 0;
        for (seeds) |s| {
            // 简单但有效的种子混合
            combined ^= s;
            combined = combined *% 0x9E3779B97F4A7C15;
            combined = std.math.rotl(u64,combined, @intCast(combined & 63));
        }
        return init(combined);
    }

    /// 从当前时间创建（非确定性）
    pub fn initTime() RNG {
        return init(@intCast(std.time.milliTimestamp()));
    }

    /// 生成下一个 u64 随机数
    pub fn next(self: *RNG) u64 {
        const result = std.math.rotl(u64,self.s[1] *% 5, 7) *% 9;
        const t = self.s[1] << 17;

        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];

        self.s[2] ^= t;
        self.s[3] = std.math.rotl(u64,self.s[3], 45);

        return result;
    }

    /// 生成 [0, max) 范围内的随机整数
    pub fn range(self: *RNG, max: u32) u32 {
        if (max <= 1) return 0;
        // 拒绝采样避免偏差
        const limit = std.math.maxInt(u32) - std.math.maxInt(u32) % max;
        while (true) {
            const r: u32 = @truncate(self.next());
            if (r < limit) return r % max;
        }
    }

    /// 生成 [min, max) 范围内的随机整数
    pub fn rangeInt(self: *RNG, min: i32, max: i32) i32 {
        if (min >= max) return min;
        const range_u: u32 = @intCast(max - min);
        return min + @as(i32, @intCast(self.range(range_u)));
    }

    /// 生成 [0, 1) 范围内的随机浮点数
    pub fn float(self: *RNG) f64 {
        const r = self.next();
        return @as(f64, @floatFromInt(r >> 11)) * 0x1.0p-53;
    }

    /// 生成正态分布随机数（Box-Muller 变换）
    pub fn normal(self: *RNG, mean: f64, stddev: f64) f64 {
        const a = self.float();
        const b = self.float();
        const z = @sqrt(-2.0 * @log(@max(a, 1e-10))) * @cos(2.0 * std.math.pi * b);
        return mean + z * stddev;
    }

    /// 从切片中随机选取一个元素
    pub fn pick(self: *RNG, items: anytype) ?@TypeOf(items[0]) {
        if (items.len == 0) return null;
        return items[self.range(@intCast(items.len))];
    }

    /// Fisher-Yates 洗牌
    pub fn shuffle(self: *RNG, items: anytype) void {
        var i: usize = items.len;
        while (i > 1) {
            i -= 1;
            const j = self.range(@intCast(i + 1));
            const tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }

    /// 返回一个布尔值，概率为 probability（0.0-1.0）
    pub fn chance(self: *RNG, probability: f64) bool {
        return self.float() < probability;
    }

    /// 掷 1dN（一颗 N 面骰子）
    pub fn dice(self: *RNG, sides: u32) u32 {
        return self.range(sides) + 1;
    }

    /// 掷 XdN（X 颗 N 面骰子求和）
    pub fn diceRoll(self: *RNG, count: u32, sides: u32) u32 {
        var total: u32 = 0;
        for (0..count) |_| {
            total += self.dice(sides);
        }
        return total;
    }

    /// SplitMix64 —— 用于初始化状态
    fn splitMix64(z: *u64) u64 {
        z.* +%= 0x9E3779B97F4A7C15;
        var r = z.*;
        r = (r ^ (r >> 30)) *% 0xBF58476D1CE4E5B9;
        r = (r ^ (r >> 27)) *% 0x94D049BB133111EB;
        return r ^ (r >> 31);
    }
};

// ============================================================================
// 测试
// ============================================================================

test "RNG deterministic" {
    var r1 = RNG.init(12345);
    var r2 = RNG.init(12345);
    for (0..100) |_| {
        try std.testing.expectEqual(r1.next(), r2.next());
    }
}

test "RNG range" {
    var r = RNG.init(42);
    for (0..1000) |_| {
        const v = r.range(100);
        try std.testing.expect(v < 100);
    }
}

test "RNG shuffle" {
    var arr = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var r = RNG.init(99);
    r.shuffle(&arr);
    // 检查所有元素仍然存在（排列不变）
    var sum: u32 = 0;
    for (arr) |v| sum += v;
    try std.testing.expectEqual(@as(u32, 36), sum);
}
