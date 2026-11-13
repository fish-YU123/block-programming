extends RefCounted
## 飞飞：默认行为 的预设玩家代码（纯字符串，给代码面板 / 新单位用）

const SOURCE := """# 飞飞：默认行为（自己的手写控制，寻路用 find_path 拿航路）
# 改下面这几个数就能让它去别的地方
目标x = 44
目标y = 0      # 0 表示"自动用地表高度 + 6 米"
目标z = 128
速度 = 6

# 传感器：pos vel cell yaw energy thrust moving blocks[5][5] blocks3[5][5][5] heights[5][5] here enemies orders
# 可用：find_path(x,y,z) 返回航路列表；go_to(x,y,z) 一行版自动驾驶
#       set_velocity(水平x速度, 水平z速度) set_altitude(高度) —— 每帧自动闭环，不会抖
#       set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后)
#       drill(True) laser(x,y,z) laser_off() shoot(x,y,z)

def start():
    print("飞飞启动，地面高度 ", heights[2][2])

def loop():
    # 队友下的指令优先
    if len(cmd) > 0:
        if cmd.action == "goto":
            set_velocity(max(-14, min(14, (cmd.x - pos.x) * 0.5)),
                         max(-14, min(14, (cmd.z - pos.z) * 0.5)))
            set_altitude(cmd.y)
            return
        if cmd.action == "hold":
            set_velocity(0.0, 0.0)
            return
    # 1) 决定去哪：有玩家的标记就去最近的标记，否则去目标点
    去x = 目标x
    去y = 目标y
    去z = 目标z
    if len(orders) > 0:
        去x = orders[0].x + 0.5
        去y = orders[0].y + 2.5
        去z = orders[0].z + 0.5
    elif 目标y == 0:
        去y = heights[2][2] + 6

    # 2) A* 算航路，自己朝航路上的第一个点飞
    航路 = find_path(去x, 去y, 去z)
    点x = 去x
    点y = 去y
    点z = 去z
    if len(航路) > 0:
        点x = 航路[0].x
        点y = 航路[0].y
        点z = 航路[0].z
    差x = 点x - pos.x
    差z = 点z - pos.z
    距离 = (差x * 差x + 差z * 差z) ** 0.5
    # 到的了这个点就按巡航速度冲，快到了就减速
    想x = max(-速度, min(速度, 差x * 1.5))
    想z = max(-速度, min(速度, 差z * 1.5))
    # 3) 下指令：想要的速度 + 想要的高度（引擎每帧自己闭环，所以不抖）
    set_velocity(想x, 想z)
    set_altitude(点y)

    # 5) 到标记旁边就干活：挖掘用钻头 + 激光
    干活 = len(orders) > 0 and orders[0].dist < 3
    drill(干活 and orders[0].action == "mine")
    if 干活 and orders[0].action == "mine":
        laser(orders[0].x + 0.5, orders[0].y + 0.5, orders[0].z + 0.5)
    else:
        laser_off()

    # 6) 看到敌人就打：15 米内开炮，5 米内再加激光
    if len(enemies) > 0:
        if enemies[0].dist <= 15:
            shoot(enemies[0].x, enemies[0].y, enemies[0].z)
        if enemies[0].dist <= 5:
            laser(enemies[0].x, enemies[0].y, enemies[0].z)
"""
