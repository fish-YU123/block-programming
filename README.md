# 方块编程（暂定名）

一个 3D 体素世界 + 玩家编写单位代码的 PVP 模拟经营游戏，目标平台 Steam（Godot 4.7）。

## 现在能玩到的东西

- 有限大小的方块世界（128×128，高度 64），程序生成地形、沙滩、矿脉
- 自由飞行视角，左键挖掘、右键放置、数字键选方块
- 内置沙箱字节码 VM：玩家写的类 Python 代码可以在游戏里安全执行，不依赖外部解释器

![预览](docs/preview.png)

## 运行

```sh
# 方式一：双击 play.command（macOS）
# 方式二：命令行
/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot --path .
```

操作：WASD 移动 / 空格上升 / Shift 下降 / Ctrl 加速 / 滚轮调速 / 左键挖掘 / 右键放置 / 数字键 1-8 选方块 / Esc 释放鼠标。

## 测试

```sh
./run_tests.sh
```

## 目录结构

```
data/blocks/      方块定义（JSON）
scenes/main.tscn  主场景
scripts/core/     游戏入口 main.gd
scripts/world/    方块表、地形生成、体素世界（区块网格/碰撞/射线）
scripts/player/   自由视角相机
scripts/ui/       HUD
scripts/lang/     沙箱字节码 VM（词法/语法/编译/虚拟机）
tests/            headless 测试与截图工具
docs/             预览图、玩家编程手册、上架与版权清单
```

## 路线图

1. ✅ 方块世界与挖掘/放置
2. ⬜ 单位系统：部署、传感器、执行玩家代码
3. ⬜ 资源与生产：矿 → 部件 → 单位
4. ⬜ 双阵营与胜负判定
5. ⬜ 联机（服务端权威）
6. ⬜ Steam 接入（GodotSteam）
