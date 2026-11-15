# 本地 Python 模式（朋友局）

游戏默认用**内置字节码 VM** 跑单位代码——它是沙箱，联机正式对局必须有它。

但如果你只是和**朋友一起玩**（或者单人调试），可以切到「本地 Python 模式」：
单位代码跑在**你自己电脑上的 python3** 里，于是

- 可以用**完整的 Python 语法**（lambda、类、列表推导、f-string、`import` 标准库……）
- 可以 `pip install` 第三方包并在代码里用
- 调试时报错更直观（真实 Python 的行号与异常）

代价：这个模式**不做沙箱**、也不参与正式对局，只在信任的朋友局里用。

## 怎么开

三种方式，任选其一：

1. 游戏里按 **F9** 切换（HUD 会提示「代码引擎：本地 Python」或「内置 VM」）
2. 启动参数：`./play.command -- --python`
3. 启动脚本里加 `export DSH_PYTHON=/path/to/python3` 指定用哪个解释器

HUD 的代码面板底部会显示「引擎：Python」或「引擎：VM」。

## 兼容性

本地 Python 模式下，游戏注入的 API 与 VM 一致（`set_lift` / `set_velocity` / `drill` / `laser` …），
传感器同样是全局变量（`pos` / `vel` / `enemies` / `orders` …）。

**建造 / 协同 / 寻路也都能用**了 —— 这些调用会通过「Python 桥」同步回调游戏本体（`tools/py_harness.py` 与游戏之间一行一个 JSON 的 RPC），语义和 VM 版完全一致：

| 接口 | 作用 |
| --- | --- |
| `team_set(键, 值)` / `team_get(键, 默认值)` | 读写**全队共享黑板**（同队所有单位都能看到） |
| `mark(x, y, z, 标签)` | 给全队标一个点（30 秒过期，同一位置会自动合并） |
| `command(uid, 动作, x, y, z)` | 直接指挥队友：`"goto"` / `"attack"` / `"hold"`（12 秒有效） |
| `place(方块名, x, y, z)` | 放方块（耗电、非自然方块扣 1 铜） |
| `build(建筑id, x, y, z)` / `build_here(建筑id)` | 在指定格 / 在附近找平地盖建筑 |
| `produce(单位id)` | 把附近的厂房改成生产某种单位 |
| `find_path(x, y, z)` | 返回 A* 航路 `[{x,y,z}, …]`，拿不到就空数组 |
| `get_link(i)` | 固定返回空数组（这套单位没有拼装部件） |

例：一台 Python 模式的侦察机可以把敌情广播给全队，再指挥炮艇去打：

```python
def loop():
    if len(enemies) > 0:
        敌 = enemies[0]
        team_set("敌情", [敌.x, 敌.y, 敌.z])
        mark(敌.x, 敌.y, 敌.z, "敌人")
        for 友 in allies:
            if 友.type == "gunship":
                command(友.uid, "attack", 敌.x, 敌.y, 敌.z)
```

## 两种引擎的差别

| | 内置 VM | 本地 Python |
| --- | --- | --- |
| 语法 | Python 子集（if/while/for/def/列表字典） | 完整 Python |
| 第三方包 | ❌ | ✅ |
| 安全 | 沙箱，可跑别人的代码 | 不沙箱，只跑自己的代码 |
| 执行节奏 | 每秒 60 行（预算制） | 每帧调用一次 `loop()`，跑到返回为止 |
| 用在 | 联机正式对局、单人 | 朋友局、单机调试、写复杂算法 |

## 注意

- 本地模式下 `loop()` 每帧跑一次，**一次执行超过 20000 行会被中断**（防死循环卡死游戏）
- 代码里 `print()` 的输出会进代码面板的「print 输出」
- 改了 `data/presets/*.py` 后，新部署的单位会自动用新代码（两种模式都支持）
- 退出游戏时 Python 子进程会一起结束；如果异常残留，可以 `pkill -f py_harness.py`
