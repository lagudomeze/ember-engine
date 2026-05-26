//! 渲染器模块 —— SDL2 + OpenGL 封装
//!
//! 基于 SDL2 窗口和 OpenGL 固定管线的图块渲染器。
//! 使用纯色矩形（GL_QUADS）渲染，避免 glBitmap 的跨平台兼容问题。
//!
//! 渲染策略：
//! - 地形：填充色块 + 小标记色块（墙壁用灰色，地板用深色）
//! - 实体：填充色块 + 中心高亮方块（表示 @ 或 * 等角色）

const std = @import("std");
const ecs = @import("ecs.zig");
const builtin = @import("builtin");

// ============================================================================
// SDL2 / OpenGL 外部声明
// ============================================================================

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
extern "c" fn SDL_GetError() [*c]const u8;

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
extern "c" fn glGetError() u32;
extern "c" fn glGetString(name: u32) [*c]const u8;

const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_PROJECTION: u32 = 0x1701;
const GL_MODELVIEW: u32 = 0x1700;
const GL_QUADS: u32 = 0x0007;
const GL_NO_ERROR: u32 = 0;
const GL_VENDOR: u32 = 0x1F00;
const GL_RENDERER: u32 = 0x1F01;
const GL_VERSION: u32 = 0x1F02;

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
// 颜色与渲染统计
// ============================================================================

pub const Color = struct {
    r: f32, g: f32, b: f32, a: f32 = 1.0,

    pub const white     = Color{ .r = 1.0, .g = 1.0, .b = 1.0 };
    pub const black     = Color{ .r = 0.0, .g = 0.0, .b = 0.0 };
    pub const red       = Color{ .r = 1.0, .g = 0.2, .b = 0.2 };
    pub const green     = Color{ .r = 0.2, .g = 1.0, .b = 0.2 };
    pub const blue      = Color{ .r = 0.2, .g = 0.2, .b = 1.0 };
    pub const yellow    = Color{ .r = 1.0, .g = 0.9, .b = 0.2 };
    pub const orange    = Color{ .r = 1.0, .g = 0.6, .b = 0.1 };
    pub const grey      = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    pub const dark_grey = Color{ .r = 0.3, .g = 0.3, .b = 0.3 };
    pub const dark_floor= Color{ .r = 0.15,.g = 0.15,.b = 0.2  };
};

pub const FrameStats = struct {
    terrain_count: u32 = 0,
    entity_count: u32 = 0,
    skipped_count: u32 = 0,
};

// ============================================================================
// 渲染器
// ============================================================================

pub const Renderer = struct {
    window: ?*SDL_Window,
    gl_context: ?*SDL_GLContext,
    width: i32,
    height: i32,
    tile_size: i32,
    tiles_wide: i32,
    tiles_high: i32,
    camera_x: i32,
    camera_y: i32,
    frame_count: u64,
    /// 是否输出每帧统计（每 60 帧输出一次）
    debug_render: bool,

    pub fn init(allocator: std.mem.Allocator, title: []const u8, width: i32, height: i32, tile_size: i32) !Renderer {
        std.debug.print("[renderer] 初始化 SDL2 视频子系统...\n", .{});

        if (SDL_Init(SDL_INIT_VIDEO) != 0) {
            const err = SDL_GetError();
            std.debug.print("[renderer] SDL_Init 失败: {s}\n", .{err});
            return error.SDLInitFailed;
        }
        std.debug.print("[renderer] SDL2 视频初始化成功\n", .{});

        const c_title = try allocator.dupeZ(u8, title);
        defer allocator.free(c_title);

        std.debug.print("[renderer] 创建窗口: {d}x{d} tile_size={d}\n", .{ width, height, tile_size });

        const window = SDL_CreateWindow(
            c_title.ptr,
            100, 100,
            width, height,
            SDL_WINDOW_SHOWN | SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE,
        ) orelse {
            const err = SDL_GetError();
            std.debug.print("[renderer] SDL_CreateWindow 失败: {s}\n", .{err});
            return error.WindowCreationFailed;
        };
        std.debug.print("[renderer] 窗口创建成功\n", .{});

        const gl_ctx = SDL_GL_CreateContext(window) orelse {
            const err = SDL_GetError();
            std.debug.print("[renderer] SDL_GL_CreateContext 失败: {s}\n", .{err});
            SDL_DestroyWindow(window);
            return error.GLContextFailed;
        };

        // 输出 OpenGL 信息
        const vendor = glGetString(GL_VENDOR);
        const renderer_str = glGetString(GL_RENDERER);
        const version = glGetString(GL_VERSION);
        std.debug.print("[renderer] OpenGL: {s} / {s} / {s}\n", .{ vendor, renderer_str, version });

        glViewport(0, 0, width, height);
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        glOrtho(0, @floatFromInt(width), @floatFromInt(height), 0, -1, 1);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();

        const err = glGetError();
        if (err != GL_NO_ERROR) {
            std.debug.print("[renderer] OpenGL 初始化错误码: {d}\n", .{err});
        }

        std.debug.print("[renderer] 渲染器初始化完成 (tiles_wide={d} tiles_high={d})\n", .{
            @divTrunc(width, tile_size),
            @divTrunc(height, tile_size),
        });

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
            .frame_count = 0,
            .debug_render = true,
        };
    }

    pub fn deinit(self: *Renderer) void {
        std.debug.print("[renderer] 关闭渲染器\n", .{});
        if (self.gl_context) |ctx| SDL_GL_DeleteContext(ctx);
        if (self.window) |win| SDL_DestroyWindow(win);
        SDL_Quit();
    }

    pub fn centerCamera(self: *Renderer, world_x: i32, world_y: i32) void {
        self.camera_x = world_x - @divTrunc(self.tiles_wide, 2);
        self.camera_y = world_y - @divTrunc(self.tiles_high, 2);
    }

    pub fn worldToScreen(self: *const Renderer, wx: i32, wy: i32) struct { sx: i32, sy: i32 } {
        return .{
            .sx = (wx - self.camera_x) * self.tile_size,
            .sy = (wy - self.camera_y) * self.tile_size,
        };
    }

    pub fn beginFrame(self: *Renderer) void {
        self.frame_count += 1;
        // 前 3 帧用鲜红色清屏，用于诊断渲染是否工作
        if (self.frame_count <= 3) {
            glClearColor(0.8, 0.1, 0.1, 1.0);
        } else {
            glClearColor(0.05, 0.05, 0.1, 1.0);
        }
        glClear(GL_COLOR_BUFFER_BIT);
        glLoadIdentity();

        // 第一帧：额外绘制一个大白方块确认 GL 工作
        if (self.frame_count == 1) {
            glColor3f(1.0, 1.0, 1.0);
            glBegin(GL_QUADS);
            glVertex2i(100, 100);
            glVertex2i(300, 100);
            glVertex2i(300, 300);
            glVertex2i(100, 300);
            glEnd();
        }
    }

    pub fn endFrame(self: *Renderer) void {
        SDL_GL_SwapWindow(self.window);
    }

    pub fn delayMs(_: *Renderer, ms: u32) void {
        SDL_Delay(ms);
    }

    /// 绘制一个地形格 —— 底色 + 字符色块
    pub fn drawTerrain(self: *const Renderer, wx: i32, wy: i32, bg: Color, ch: u8, fg: Color) void {
        const screen = self.worldToScreen(wx, wy);
        if (screen.sx < -self.tile_size or screen.sx > self.width) return;
        if (screen.sy < -self.tile_size or screen.sy > self.height) return;

        const margin: i32 = 0;
        const sx = screen.sx + margin;
        const sy = screen.sy + margin;
        const sz = self.tile_size - margin * 2;

        // 底色方块
        glColor3f(bg.r, bg.g, bg.b);
        glBegin(GL_QUADS);
        glVertex2i(sx, sy);
        glVertex2i(sx + sz, sy);
        glVertex2i(sx + sz, sy + sz);
        glVertex2i(sx, sy + sz);
        glEnd();

        // 字符中心标记（占 tile 的 40% 大小的方块）
        _ = ch;
        const inset = @divTrunc(sz, 3);
        const cx = sx + inset;
        const cy = sy + inset;
        const csz = sz - inset * 2;

        glColor3f(fg.r, fg.g, fg.b);
        glBegin(GL_QUADS);
        glVertex2i(cx, cy);
        glVertex2i(cx + csz, cy);
        glVertex2i(cx + csz, cy + csz);
        glVertex2i(cx, cy + csz);
        glEnd();
    }

    /// 绘制实体 —— 填充色块 + 中心高亮标记
    pub fn drawEntity(self: *const Renderer, wx: i32, wy: i32, color: Color) void {
        const screen = self.worldToScreen(wx, wy);
        if (screen.sx < -self.tile_size or screen.sx > self.width) return;
        if (screen.sy < -self.tile_size or screen.sy > self.height) return;

        const sz = self.tile_size;

        // 实体底色（半透明大色块）
        glColor3f(color.r * 0.3, color.g * 0.3, color.b * 0.3);
        glBegin(GL_QUADS);
        glVertex2i(screen.sx, screen.sy);
        glVertex2i(screen.sx + sz, screen.sy);
        glVertex2i(screen.sx + sz, screen.sy + sz);
        glVertex2i(screen.sx, screen.sy + sz);
        glEnd();

        // 实体中心标记（亮色小方块，占 50%）
        const inset = @divTrunc(sz, 4);
        const cx = screen.sx + inset;
        const cy = screen.sy + inset;
        const csz = sz - inset * 2;

        glColor3f(color.r, color.g, color.b);
        glBegin(GL_QUADS);
        glVertex2i(cx, cy);
        glVertex2i(cx + csz, cy);
        glVertex2i(cx + csz, cy + csz);
        glVertex2i(cx, cy + csz);
        glEnd();
    }

    /// 绘制屏幕文字（调试/UI用）—— 使用矩形近似
    pub fn drawText(self: *const Renderer, x: i32, y: i32, text: []const u8, color: Color) void {
        _ = self;
        glColor3f(color.r, color.g, color.b);
        var px = x;
        for (text) |ch| {
            if (ch > ' ') {
                // 用填充矩形模拟字符
                glBegin(GL_QUADS);
                glVertex2i(px, y - 10);
                glVertex2i(px + 6, y - 10);
                glVertex2i(px + 6, y);
                glVertex2i(px, y);
                glEnd();
            }
            px += 8;
        }
    }
};

// ============================================================================
// 输入系统
// ============================================================================

pub const InputState = struct {
    keys: [512]bool = [_]bool{false} ** 512,
    quit: bool = false,

    pub fn init() InputState {
        return .{};
    }
};

pub fn pollInput(state: *InputState) void {
    var event: SDL_Event = undefined;
    const kb_state = SDL_GetKeyboardState(null);
    for (0..512) |i| {
        state.keys[i] = kb_state[i] != 0;
    }
    while (SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            SDL_QUIT => {
                std.debug.print("[input] SDL_QUIT 事件\n", .{});
                state.quit = true;
            },
            SDL_KEYDOWN => {
                std.debug.print("[input] SDL_KEYDOWN scancode={d}\n", .{event.key.keysym.scancode});
                state.keys[event.key.keysym.scancode] = true;
            },
            else => {
                // 输出其他事件类型帮助诊断
                if (event.type != 0) {
                    std.debug.print("[input] 事件 type={d}\n", .{event.type});
                }
            },
        }
    }
}

pub const Scancode = enum(u32) {
    a = 4, b = 5, c = 6, d = 7, e = 8, f = 9, g = 10,
    h = 11, i = 12, j = 13, k = 14, l = 15, m = 16,
    n = 17, o = 18, p = 19, q = 20, r = 21, s = 22,
    t = 23, u = 24, v = 25, w = 26, x = 27, y = 28, z = 29,
    _1 = 30, _2 = 31, _3 = 32, _4 = 33, _5 = 34,
    _6 = 35, _7 = 36, _8 = 37, _9 = 38, _0 = 39,
    up = 82, down = 81, left = 80, right = 79,
    escape = 41, space = 44, @"return" = 40,
    _,

    pub fn isPressed(self: Scancode, state: *const InputState) bool {
        return state.keys[@intFromEnum(self)];
    }
};
