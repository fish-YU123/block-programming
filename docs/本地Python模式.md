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

目前**本地模式还不支持**这几个接口，调用会抛 `NotImplementedError`：

- `place()` 放方块、`build()` / `build_here()` 造建筑、`produce()` 改厂房产线
- `mark()` / `team_set()` / `team_get()` / `command()` 队伍协同
- `find_path()` 会返回空数组（不走 A*）

也就是说：**飞控制、开火、挖矿、传感器**全都能用，**建造/协同**暂时只有 VM 支持。

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
