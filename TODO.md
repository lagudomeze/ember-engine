# TODO —— Ember Engine 对照 ToME4 原版差距分析

> 基准：原 ToME4 (t-engine4-master) C 引擎 + Lua 游戏层
> 目标：Ember Engine (Zig) 达到同等甚至更强的游戏引擎能力

---

## A. 种族与角色创建
- [ ] **A1. 种族系统** —— 参考 `data/birth/races/` (Human, Elf, Dwarf, Halfling, Undead, Krog, Yeek 等)，每个种族有属性修正、天赋加成、经验惩罚
- [ ] **A2. 职业系统** —— 参考 `data/birth/classes/` (Warrior, Rogue, Mage, Wilder, Celestial, Defiler, Chronomancer, Psionic, Afflicted, Tinker 等)，每个职业有起始装备、解锁天赋树、属性分配
- [ ] **A3. 角色创建流程 (Birther)** —— 参考 `engine/Birther.lua`，多步骤角色创建（种族→职业→外观→属性分配→天赋选择→确认）
- [ ] **A4. 属性系统 (Stats)** —— 参考 `ActorStats.lua`，6 主属性 (STR/DEX/CON/MAG/WIL/CUN) + 派生属性 (life/mana regen, encumbrance, speed 等)

## B. 天赋与技能系统
- [ ] **B1. 天赋树框架** —— 参考 `ActorTalents.lua` 的 `newTalent()` / `newTalentType()`，天赋类型、天赋树结构、天赋点分配
- [ ] **B2. 天赋模式** —— Active (主动施放)、Sustain (持续维持，扣资源上限)、Passive (被动生效)
- [ ] **B3. 冷却系统** —— 每个天赋独立的 cooldown 计时器
- [ ] **B4. 天赋交互** —— 天赋触发条件 (on_learn/on_unlearn/on_pre_use/on_move 等回调)
- [ ] **B5. 资源系统** —— 参考 `ActorResource.lua`，Mana/Stamina/Equilibrium/Vim/Positive/Negative/Paradox/Steam/Psi/Hate/Souls 等多资源类型

## C. 战斗与伤害系统
- [ ] **C1. 伤害类型框架** —— 参考 `data/damage_types.lua`，10+ 种伤害类型 (Physical/Fire/Cold/Lightning/Arcane/Blight/Light/Darkness/Mind/Temporal 等)，每种有独立的 `projector()` 函数
- [ ] **C2. 抗性与弱点** —— 每种伤害类型对应 resist/allres/immune 穿透计算
- [ ] **C3. 护甲与穿透** —— APR (Armor Penetration) 与 Armor 的计算
- [ ] **C4. 暴击系统** —— 暴击率/暴击倍率，法术暴击 vs 物理暴击
- [ ] **C5. 命中计算** —— Accuracy vs Defense，命中检查
- [ ] **C6. 伤害投射** —— 参考 `ActorProject.lua`，投射物/光束/锥形/爆炸/球形的统一定义
- [ ] **C7. 状态效果 (Timed Effects)** —— 参考 `ActorTemporaryEffects.lua` 和 `data/timed_effects.lua`，增益/减益效果，持续回合，叠加规则

## D. 物品与装备
- [ ] **D1. 物品类型** —— 参考 `class/Object.lua` 和 `data/general/objects/`，武器/护甲/宝石/卷轴/药水/魔杖/戒指/弹药/神器/灯具/工具
- [ ] **D2. 装备槽位** —— 参考 `ActorInventory.lua`，主手/副手/身体/头部/手部/脚部/披风/项链/戒指(×2)/工具/灯具/弹药 等
- [ ] **D3. 物品属性词缀** —— 前缀/后缀系统 (ego system)，生成随机魔法属性
- [ ] **D4. 物品栏管理** —— 拾取/放下/装备/卸下/使用/丢弃，负重限制
- [ ] **D5. 神器系统** —— 唯一物品，固定属性，特殊能力，显示特殊颜色

## E. AI 系统
- [ ] **E1. 行为树框架** —— 替换当前简单 AI，建立可组合的行为树节点
- [ ] **E2. 战术 AI** —— 参考 ToME 的 `tactical.lua`/`improved_tactical.lua`，评估攻击/防御/逃跑/支援的战术价值
- [ ] **E3. 天赋使用 AI** —— 参考 `improved_talented.lua`，AI 能智能选择和使用天赋
- [ ] **E4. AI 类型** —— escort (护送)/summon (召唤物)/party (队友)/maintenance (维护)/heal (治疗) 等专用 AI
- [ ] **E5. 阵营系统** —— 参考 `Faction.lua`，友好/中立/敌对关系矩阵，声望增减

## F. 地图与关卡
- [ ] **F1. 多层级地图** —— 参考 `Map.lua`，TERRAIN/TRAP/ACTOR/PROJECTILE/OBJECT 5 层，每层独立管理
- [ ] **F2. 地图生成器扩展** —— BSP (房间+走廊)、元胞自动机 (洞穴)、迷宫、森林、建筑、城镇 等多算法
- [ ] **F3. 区域系统 (Zone)** —— 参考 `Zone.lua`，区域定义 → 关卡生成调度 → NPC/物品/陷阱放置
- [ ] **F4. 区域持久化** —— 参考 `persist_last_zones`，重访区域时恢复之前的关卡状态
- [ ] **F5. 平滑滚动** —— 摄像机平滑过渡，支持动画移动
- [ ] **F6. 瓦片地图渲染** —— 参考 `ModdableGridMaker.lua` 和 `tilesets/`，ASCII 和图形瓦片双模式
- [ ] **F7. 世界地图** —— 参考 `class/World.lua`，大地图探索，枢纽加载/卸载，随机遭遇

## G. 存档系统
- [ ] **G1. ZIP 存档格式** —— 参考 `Savefile.lua`/`serial.c`，将游戏状态序列化为 ZIP 文件，每个实体一个文件
- [ ] **G2. 递归序列化** —— 实体自动序列化，`save()`/`loaded()` 钩子用于复杂对象
- [ ] **G3. 后台存档** —— 异步保存，不阻塞游戏循环
- [ ] **G4. 快速重生** —— 保存最近的"好"状态以支持快速重生
- [ ] **G5. 存档校验** —— MD5 校验防止存档损坏

## H. UI 系统
- [ ] **H1. 对话框栈** —— 参考 `Dialog.lua`，模态对话框栈，支持嵌套
- [ ] **H2. UI 主题** —— 参考 `uiset/` (Classic/Minimalist)，可切换的 UI 布局
- [ ] **H3. 热键栏** —— 参考 `PlayerHotkeys.lua`，可配置的技能/物品热键
- [ ] **H4. 角色面板** —— 属性/天赋/物品栏/任务/成就等 UI 面板
- [ ] **H5. 战斗日志** —— 滚动的战斗信息窗口
- [ ] **H6. 工具提示** —— 参考 `TooltipsData.lua`，物品/天赋/状态悬浮提示
- [ ] **H7. 小地图** —— 当前关卡的缩略地图

## I. 音频
- [ ] **I1. OpenAL 后端** —— 替换当前无音频状态，3D 空间音效
- [ ] **I2. 音乐系统** —— 参考 `music.c`/`GameMusic.lua`，Ogg Vorbis 流式播放，环境氛围切换
- [ ] **I3. 音效系统** —— 参考 `GameSound.lua`，战斗/移动/魔法/环境音效
- [ ] **I4. 音量控制** —— 独立的主音量/音乐/音效控制

## J. 输入系统
- [ ] **J1. 鼠标支持** —— 点击移动/瞄准/交互
- [ ] **J2. 触摸支持** —— 移动端手势 (SDL_FINGERDOWN/MOTION)
- [ ] **J3. 游戏手柄** —— SDL 摇杆/按钮映射
- [ ] **J4. 快捷键绑定** —— 参考 `data/keybinds/`，可配置的键位绑定

## K. 网络与社区
- [ ] **K1. 在线档案** —— 玩家数据同步到服务器
- [ ] **K2. 游戏内聊天** —— 参考 `UserChat.lua`/`ChatChannels.lua`
- [ ] **K3. 成就系统** —— 参考 `WorldAchievements.lua`

## L. 任务与叙事
- [ ] **L1. 任务系统** —— 参考 `Quest.lua`，任务状态机 (未开始/进行中/完成/失败)
- [ ] **L2. 对话系统** —— 参考 `Chat.lua`，NPC 对话树
- [ ] **L3. 商店系统** —— 参考 `Store.lua`，买卖界面，库存刷新
- [ ] **L4. 游戏内时间** —— 参考 `Calendar.lua`，昼夜循环，日期推进

## M. 粒子与视觉效果
- [ ] **M1. 粒子系统** —— 参考 `particles.c`/`Particles.lua`，发射器/生命期/颜色/大小动画
- [ ] **M2. 着色器效果** —— 全屏后处理 (扭曲/发光/体积光)
- [ ] **M3. 天气系统** —— 雨/雪/沙尘暴等地图级粒子

## N. 工具与编辑器
- [ ] **N1. 地图编辑器** —— 可视化地牢/区域设计
- [ ] **N2. 天赋树设计器** —— 可视化创建天赋和天赋树
- [ ] **N3. 物品/怪物编辑器** —— 带实时预览的数据编辑器
- [ ] **N4. 调试控制台** —— 运行时查询/修改 ECS 状态，Lua/脚本 REPL

## O. 引擎底层
- [ ] **O1. RNG 系统** —— 参考 `SFMT.c`，Mersenne Twister SIMD 优化的伪随机数
- [ ] **O2. 噪声函数** —— 参考 `noise.c`，Perlin/Simplex 噪声，用于地形生成
- [ ] **O3. 物理文件系统** —— 参考 `physfs.c`，虚拟文件系统，.team/.teae 归档支持
- [ ] **O4. 国际化 I18N** —— 参考 `I18N.lua`，多语言支持，`_t()` 翻译函数
- [ ] **O5. 名称生成器** —— 参考 `NameGenerator.lua`，程序化种族名称生成
- [ ] **O6. A* 路径查找实现** —— 在 `world.zig` 中补全路径查找算法
- [ ] **O7. Wasmtime 完整绑定** —— 完成 `plugin_wasm.zig` 中的 C API 集成

---

## 优先级

**P0 (立即)**: O6, O1, E1-E2
**P1 (短期)**: A1-A4, B1-B5, C1-C7, D1-D2
**P2 (中期)**: F1-F7, G1-G3, H1-H7
**P3 (长期)**: 其余全部

---

> 共 15 大类，72 项待实现任务
