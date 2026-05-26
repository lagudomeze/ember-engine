//! 渲染器模块 —— SDL2 与 OpenGL 封装
//!
//! 提供跨平台的窗口管理和基于图块的渲染。
//! 设计为可替换的后端：修改此模块即可切换到 WebGPU、Vulkan 等。
//!
//! 当前实现：
//! - SDL2 创建窗口和 OpenGL 上下文
//! - 使用纹理图集进行图块渲染
//! - 支持键盘输入处理
//! - 文本渲染（简易 ASCII 风格）

const std = @import("std");
const ecs = @import("ecs.zig");

// ============================================================================
// SDL2 外部函数声明（C ABI）
// ============================================================================

// 注意：实际使用时需要链接 SDL2 库。
// 这些声明为编译提供符号引用，链接时由系统 SDL2 库解析。

const SDL_WINDOW_SHOWN: u32 = 0x00000004;
const SDL_WINDOW_OPENGL: u32 = 0x00000002;
const SDL_WINDOW_RESIZABLE: u32 = 0x00000020;
const SDL_INIT_VIDEO: u32 = 0x00000020;

const SDL_KEYDOWN: u32 = 0x300;
const SDL_QUIT: u32 = 0x100;

extern "c" fn SDL_Init(flags: u32) c_int;
extern "c" fn SDL_Quit() void;
extern "c" fn SDL_CreateWindow(title: [*c]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*SDL_Window;
extern "c" fn SDL_DestroyWindow(window: ?*SDL_Window) void;
extern "c" fn SDL_GL_CreateContext(window: ?*SDL_Window) ?*SDL_GLContext;
extern "c" fn SDL_GL_DeleteContext(context: ?*SDL_GLContext) void;
extern "c" fn SDL_GL_SwapWindow(window: ?*SDL_Window) void;
extern "c" fn SDL_PollEvent(event: *SDL_Event) c_int;
extern "c" fn SDL_GetTicks() u32;
extern "c" fn SDL_Delay(ms: u32) void;
extern "c" fn SDL_GetKeyboardState(numkeys: ?*c_int) [*c]u8;

// OpenGL 函数（仅使用基础功能）
extern "c" fn glClear(mask: u32) void;
extern "c" fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
extern "c" fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) void;
extern "c" fn glMatrixMode(mode: u32) void;
extern "c" fn glLoadIdentity() void;
extern "c" fn glOrtho(left: f64, right: f64, bottom: f64, top: f64, near: f64, far: f64) void;
extern "c" fn glBegin(mode: u32) void;
extern "c" fn glEnd() void;
extern "c" fn glColor3f(r: f32, g: f32, b: f32) void;
extern "c" fn glVertex2i(x: i32, y: i32) void;
extern "c" fn glRasterPos2i(x: i32, y: i32) void;
extern "c" fn glBitmap(width: i32, height: i32, xorig: f32, yorig: f32, xmove: f32, ymove: f32, bitmap: [*c]const u8) void;

const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_PROJECTION: u32 = 0x1701;
const GL_MODELVIEW: u32 = 0x1700;
const GL_QUADS: u32 = 0x0007;

// 不透明类型
const SDL_Window = extern struct { _unused: u8 };
const SDL_GLContext = extern struct { _unused: u8 };

pub const SDL_Event = extern union {
    type: u32,
    key: SDL_KeyboardEvent,
};

pub const SDL_KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    state: u8,
    repeat: u8,
    padding2: u8,
    padding3: u8,
    keysym: SDL_Keysym,
};

pub const SDL_Keysym = extern struct {
    scancode: u32,
    sym: i32,
    mod_: u16,
    unused: u32,
};

// ============================================================================
// 颜色定义
// ============================================================================

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub const white = Color{ .r = 1.0, .g = 1.0, .b = 1.0 };
    pub const black = Color{ .r = 0.0, .g = 0.0, .b = 0.0 };
    pub const red = Color{ .r = 1.0, .g = 0.2, .b = 0.2 };
    pub const green = Color{ .r = 0.2, .g = 1.0, .b = 0.2 };
    pub const blue = Color{ .r = 0.2, .g = 0.2, .b = 1.0 };
    pub const yellow = Color{ .r = 1.0, .g = 1.0, .b = 0.2 };
    pub const orange = Color{ .r = 1.0, .g = 0.6, .b = 0.1 };
    pub const grey = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    pub const dark_grey = Color{ .r = 0.3, .g = 0.3, .b = 0.3 };
};

// ============================================================================
// 渲染器
// ============================================================================

/// 图块渲染器 —— 负责窗口管理、图块绘制和输入收集
pub const Renderer = struct {
    window: ?*SDL_Window,
    gl_context: ?*SDL_GLContext,
    /// 窗口宽度（像素）
    width: i32,
    /// 窗口高度（像素）
    height: i32,
    /// 每个图块的像素大小
    tile_size: i32,
    /// 视口在水平方向能显示的图块数
    tiles_wide: i32,
    /// 视口在垂直方向能显示的图块数
    tiles_high: i32,
    /// 摄像机在世界坐标中的位置（左上角）
    camera_x: i32,
    camera_y: i32,
    /// 上一帧的按键状态（用于检测按键按下）
    prev_keys: [512]bool,

    /// 创建渲染器实例
    pub fn init(allocator: std.mem.Allocator, title: []const u8, width: i32, height: i32, tile_size: i32) !Renderer {

        if (SDL_Init(SDL_INIT_VIDEO) != 0) {
            return error.SDLInitFailed;
        }

        const c_title = try allocator.dupeZ(u8, title);
        defer allocator.free(c_title);

        const window = SDL_CreateWindow(
            c_title.ptr,
            100, 100,
            width, height,
            SDL_WINDOW_SHOWN | SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE,
        ) orelse return error.WindowCreationFailed;

        const gl_ctx = SDL_GL_CreateContext(window) orelse {
            SDL_DestroyWindow(window);
            return error.GLContextFailed;
        };

        // 设置 OpenGL 的正交投影
        glViewport(0, 0, width, height);
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        glOrtho(0, @floatFromInt(width), @floatFromInt(height), 0, -1, 1);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();

        return Renderer{
            .window = window,
            .gl_context = gl_ctx,
            .width = width,
            .height = height,
            .tile_size = tile_size,
            .tiles_wide = @divTrunc(width, tile_size),
            .tiles_high = @divTrunc(height, tile_size),
            .camera_x = 0,
            .camera_y = 0,
            .prev_keys = [_]bool{false} ** 512,
        };
    }

    /// 销毁渲染器
    pub fn deinit(self: *Renderer) void {
        if (self.gl_context) |ctx| {
            SDL_GL_DeleteContext(ctx);
        }
        if (self.window) |win| {
            SDL_DestroyWindow(win);
        }
        SDL_Quit();
    }

    /// 将摄像机居中到指定世界坐标
    pub fn centerCamera(self: *Renderer, world_x: i32, world_y: i32) void {
        self.camera_x = world_x - @divTrunc(self.tiles_wide, 2);
        self.camera_y = world_y - @divTrunc(self.tiles_high, 2);
    }

    /// 将世界坐标转换为屏幕像素坐标
    pub fn worldToScreen(self: *const Renderer, wx: i32, wy: i32) struct { sx: i32, sy: i32 } {
        return .{
            .sx = (wx - self.camera_x) * self.tile_size,
            .sy = (wy - self.camera_y) * self.tile_size,
        };
    }

    /// 开始新帧
    pub fn beginFrame(_: *Renderer) void {
        glClearColor(0.05, 0.05, 0.1, 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        glLoadIdentity();
    }

    /// 结束帧（交换缓冲区）
    pub fn endFrame(self: *Renderer) void {
        SDL_GL_SwapWindow(self.window);
    }

    /// 延迟指定毫秒数（用于帧率控制）
    pub fn delayMs(_: *Renderer, ms: u32) void {
        SDL_Delay(ms);
    }

    /// 绘制一个字符图块
    pub fn drawChar(self: *const Renderer, wx: i32, wy: i32, ch: u8, color: Color) void {
        const screen = self.worldToScreen(wx, wy);

        // 裁剪：只绘制屏幕内的图块
        if (screen.sx < -self.tile_size or screen.sx > self.width) return;
        if (screen.sy < -self.tile_size or screen.sy > self.height) return;

        glColor3f(color.r, color.g, color.b);

        // 绘制字符背景（小方块）
        glBegin(GL_QUADS);
        glVertex2i(screen.sx, screen.sy);
        glVertex2i(screen.sx + self.tile_size - 1, screen.sy);
        glVertex2i(screen.sx + self.tile_size - 1, screen.sy + self.tile_size - 1);
        glVertex2i(screen.sx, screen.sy + self.tile_size - 1);
        glEnd();

        // 绘制字符前景（使用 glBitmap 渲染 ASCII 字符）
        glColor3f(0.9, 0.9, 0.9);
        glRasterPos2i(screen.sx + 2, screen.sy + self.tile_size - 4);

        // 简单的 8x8 位图字符渲染
        const bitmap = getCharBitmap(ch);
        glBitmap(8, 8, 0, 0, 8, 0, @ptrCast(&bitmap));
    }

    /// 绘制一个纯色方块（用于未实现字符渲染时的后备方案）
    pub fn drawTile(self: *const Renderer, wx: i32, wy: i32, color: Color) void {
        const screen = self.worldToScreen(wx, wy);
        if (screen.sx < -self.tile_size or screen.sx > self.width) return;
        if (screen.sy < -self.tile_size or screen.sy > self.height) return;

        glColor3f(color.r, color.g, color.b);
        glBegin(GL_QUADS);
        glVertex2i(screen.sx + 1, screen.sy + 1);
        glVertex2i(screen.sx + self.tile_size - 1, screen.sy + 1);
        glVertex2i(screen.sx + self.tile_size - 1, screen.sy + self.tile_size - 1);
        glVertex2i(screen.sx + 1, screen.sy + self.tile_size - 1);
        glEnd();
    }

    /// 绘制一条文本消息（用于 UI）
    pub fn drawText(self: *const Renderer, x: i32, y: i32, text: []const u8, color: Color) void {
        _ = self;
        glColor3f(color.r, color.g, color.b);
        for (text, 0..) |ch, i| {
            glRasterPos2i(x + @as(i32, @intCast(i)) * 8, y);
            if (ch >= 32 and ch < 127) {
                const bitmap = getCharBitmap(ch);
                glBitmap(8, 8, 0, 0, 8, 0, @ptrCast(&bitmap));
            }
        }
    }
};

// ============================================================================
// 输入系统
// ============================================================================

/// 按键动作
pub const KeyAction = enum {
    none,
    pressed,
    released,
    repeat,
};

/// 键盘输入状态 —— 每帧更新
pub const InputState = struct {
    /// 当前帧按下的按键集合
    keys: [512]bool = [_]bool{false} ** 512,
    /// 是否请求退出
    quit: bool = false,
    /// 鼠标位置（屏幕坐标）
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,

    pub fn init() InputState {
        return .{};
    }
};

/// 处理输入事件，更新输入状态
pub fn pollInput(state: *InputState) void {
    var event: SDL_Event = undefined;

    // 重置按键状态（只保留按键按住的状态用于持续检测）
    const kb_state = SDL_GetKeyboardState(null);
    for (0..512) |i| {
        state.keys[i] = kb_state[i] != 0;
    }

    while (SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            SDL_QUIT => {
                state.quit = true;
            },
            SDL_KEYDOWN => {
                state.keys[event.key.keysym.scancode] = true;
            },
            else => {},
        }
    }
}

/// SDL 扫描码常量
pub const Scancode = enum(u32) {
    a = 4,
    b = 5,
    c = 6,
    d = 7,
    e = 8,
    f = 9,
    g = 10,
    h = 11,
    i = 12,
    j = 13,
    k = 14,
    l = 15,
    m = 16,
    n = 17,
    o = 18,
    p = 19,
    q = 20,
    r = 21,
    s = 22,
    t = 23,
    u = 24,
    v = 25,
    w = 26,
    x = 27,
    y = 28,
    z = 29,
    _1 = 30,
    _2 = 31,
    _3 = 32,
    _4 = 33,
    _5 = 34,
    _6 = 35,
    _7 = 36,
    _8 = 37,
    _9 = 38,
    _0 = 39,
    up = 82,
    down = 81,
    left = 80,
    right = 79,
    escape = 41,
    space = 44,
    @"return" = 40,
    _,

    pub fn isPressed(self: Scancode, state: *const InputState) bool {
        return state.keys[@intFromEnum(self)];
    }
};

// ============================================================================
// 字符位图 —— 简易 8x8 字体
// ============================================================================

/// 获取字符的 8x8 位图数据（每字节一行，共 8 字节）
fn getCharBitmap(ch: u8) [8]u8 {
    // 简化的 8x8 位图字体 —— 仅包含常用字符
    return switch (ch) {
        '@' => .{ 0x3C, 0x42, 0x99, 0xA1, 0xA1, 0x99, 0x42, 0x3C },
        '*' => .{ 0x00, 0x24, 0x18, 0x7E, 0x18, 0x24, 0x00, 0x00 },
        '#' => .{ 0x28, 0x7C, 0x28, 0x7C, 0x28, 0x7C, 0x28, 0x00 },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x00 },
        '-' => .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
        '|' => .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
        '+' => .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 },
        '<' => .{ 0x00, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x00, 0x00 },
        '>' => .{ 0x00, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x00, 0x00 },
        '~' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        else   => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
}
