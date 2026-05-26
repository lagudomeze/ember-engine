# Ember Engine

**T-Engine Zig —— Tales of Maj'Eyal: Zig Edition**

基于 Zig 的 roguelike 游戏引擎，灵感来源于《Tales of Maj'Eyal》(ToME4)。以 ECS 架构、编译时插件融合和 Wasm 运行时扩展为核心，追求零开销抽象和可预测的性能。

---

## 设计理念

| 原则 | 实现 |
|------|------|
| **显式** | 所有内存分配通过 allocator 参数传递，无隐藏全局状态 |
| **无魔法** | 组件 ID 手动分配，系统调度表编译期生成，全程可追踪 |
| **性能可预测** | 无数表查找、无字符串哈希、无动态分配 —— 热路径全部静态分发 |

## 架构概览

```
┌──────────────────────────────────────────────┐
│                 游戏主循环                     │
│          输入 → 系统调度 → 渲染               │
├──────────────────────────────────────────────┤
│  ECS 世界                                    │
│  ┌─────────┐  ┌─────────┐  ┌─────────────┐  │
│  │ Entity  │  │Component│  │   System     │  │
│  │ (句柄)  │  │Storage  │  │  (纯函数)    │  │
│  │         │  │(稀疏集) │  │             │  │
│  └─────────┘  └─────────┘  └─────────────┘  │
├──────────────────────────────────────────────┤
│  插件层                                       │
│  ┌──────────────────┐  ┌──────────────────┐  │
│  │ 编译时融合插件    │  │ Wasm 运行时插件   │  │
│  │ (comptime 收集)  │  │ (wasmtime 沙箱)  │  │
│  └──────────────────┘  └──────────────────┘  │
├──────────────────────────────────────────────┤
│  平台抽象层                                   │
│  ┌────────┐  ┌────────┐  ┌───────────────┐  │
│  │ SDL2   │  │OpenGL  │  │  世界/地图/FOV │  │
│  └────────┘  └────────┘  └───────────────┘  │
└──────────────────────────────────────────────┘
```

## 项目结构

```
├── build.zig                       # 构建脚本
├── README.md
├── ROADMAP.md
├── wasm_mod_template.zig           # Wasm 插件模板
└── src/
    ├── main.zig                    # 入口，游戏循环
    ├── engine/
    │   ├── ecs.zig                 # 实体/组件/系统核心
    │   ├── world.zig               # 地图/区块/FOV/寻路
    │   ├── plugin_comptime.zig     # 编译时插件系统
    │   ├── plugin_wasm.zig         # Wasm 插件运行时
    │   └── renderer.zig            # SDL2/OpenGL 渲染
    └── plugins/
        ├── core_class_firemage.zig # 火法师职业
        └── core_ai_hostile.zig     # 敌对 AI
```

## 快速开始

### 依赖

- **Zig** 0.16.0+
- **SDL2** 开发库（`libsdl2-dev`）
- **OpenGL**（通常随显卡驱动提供）
- **Wasmtime**（可选，用于 Wasm 插件支持）

```bash
# Ubuntu/Debian
sudo apt install libsdl2-dev

# macOS
brew install sdl2

# Windows
# 下载 SDL2 开发库并配置路径
```

### 构建与运行

```bash
# 编译
zig build

# 运行
zig build run

# 运行测试
zig build test

# 发布模式
zig build -Doptimize=ReleaseFast
```

### 游戏操作

| 按键 | 功能 |
|------|------|
| `WASD` / 方向键 | 移动 |
| `1` | 施放火球术 |
| `5` / 空格 | 等待一回合 |
| `ESC` | 退出 |

## 核心特性

### ECS 架构

- **Entity**：64 位句柄（index + generation），解决 ABA 问题
- **Component**：纯数据 struct，通过稀疏集合（Sparse Set）存储
- **System**：纯函数，操作组件数据，按阶段有序执行
- **Event**：系统间松耦合通信，先收集后分发

### 编译时插件系统

```zig
// 每个插件导出 manifest
pub const manifest = plugin.PluginManifest{
    .name = "火法师职业",
    .components = &.{ ... },
    .systems = &.{
        plugin.systemEntry("投射物移动", .movement, projectileSystem),
        plugin.systemEntry("灼烧状态", .status_effect, burningSystem),
    },
};

// 编译期收集所有插件，生成零开销调度表
const registry = plugin.PluginRegistry.collect(ALL_PLUGINS);
const system_table = registry.buildSystemTable();
```

### Wasm 插件支持

通过共享内存缓冲区 + C ABI 与 Wasm 模块通信，避免内存拷贝。模块运行在沙箱中，受资源限制保护。

### 世界与地图

- 区块化管理（32×32 格），按需加载/卸载
- 程序化生成（可替换为 BSP、元胞自动机等算法）
- 递归阴影投射 FOV 算法
- 预留 A* 寻路接口

## 当前演示

游戏启动后展示：
- `@` 黄色 = 玩家（100 HP / 100 MP）
- `*` 绿色 = 敌对生物（5 只）
- `*` 红色 = 火球投射物
- `#` / `.` = 墙壁 / 地板

火球术命中敌人造成伤害并附加**灼烧**状态（3 回合持续火焰伤害）。敌人拥有视野和追击 AI。

## 路线图

详见 [ROADMAP.md](ROADMAP.md)。

## 许可

参见 [LICENSE](LICENSE) 文件（如有）或沿用原 ToME4 的 GPL 许可。
