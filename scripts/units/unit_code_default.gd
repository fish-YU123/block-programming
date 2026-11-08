extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）
##
## 每个单位支持两个固定函数：
##   def start():  开局（或点「应用」）时跑一次
##   def loop():   之后一直反复跑
## 两个都不写的话，整段代码会从头循环执行（老写法仍然有效）。

const FLYER_SOURCE := """# 飞飞：默认行为（自己的手写控制，寻路用 find_path 拿航路）
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

## 红方无人机：追最近的敌方单位，贴上去开钻
const RED_SOURCE := """# 红方无人机（脚本 AI）
def loop():
    目标高度 = heights[2][2] + 8
    期望速度 = 0.0
    距离 = 999.0
    if len(enemies) > 0:
        敌 = enemies[0]
        距离 = 敌.x - pos.x
        期望速度 = max(-7, min(7, 距离 * 1.2))
        if abs(距离) < 1.5:
            期望速度 = 0
    误差 = 目标高度 - pos.y
    set_lift(0.57 + 误差 * 0.15 - vel.y * 0.1)
    set_rcs(0, -vel.z * 0.6)
    set_tilt(max(-1, min(1, (vel.x - 期望速度) * 0.08)), 0)
    if len(enemies) > 0:
        纵向 = 敌.y - pos.y
        drill(abs(距离) < 2.5 and abs(纵向) < 2.5)
    else:
        drill(False)
"""

## 对局用的格斗预设：自动找最近敌人，靠近后炮击 / 激光 / 钻头齐上
const FIGHTER_SOURCE := """# 飞飞格斗预设（两边开局都用它，会自动打起来）
# 结构：start() 跑一次，loop() 每分钟 60 行预算里反复跑
def start():
    print("飞飞出击")

def loop():
    高度 = heights[2][2] + 8
    有敌人 = len(enemies) > 0
    if 有敌人:
        高度 = enemies[0].y
        if enemies[0].dist > 4:
            set_velocity(max(-30, min(30, (enemies[0].x - pos.x) * 1.2)), max(-30, min(30, (enemies[0].z - pos.z) * 1.2)))
        else:
            set_velocity(0, 0)
        if enemies[0].dist <= 15:
            shoot(enemies[0].x, enemies[0].y, enemies[0].z)
        if enemies[0].dist <= 5:
            drill(True)
            laser(enemies[0].x, enemies[0].y, enemies[0].z)
        else:
            drill(False)
            laser_off()
    else:
        drill(False)
        laser_off()
        # 没看到敌人（雷达 10 米）就往对面冲，速度给足
        if pos.x < 128:
            set_velocity(30, 0)
        else:
            set_velocity(-30, 0)
    set_altitude(高度)
"""
