extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）
##
## 每个单位支持两个固定函数：
##   def start():  开局（或点「应用」）时跑一次
##   def loop():   之后一直反复跑
## 两个都不写的话，整段代码会从头循环执行（老写法仍然有效）。

const FLYER_SOURCE := """# 飞飞：默认行为
# 想让它去哪，就改下面这几个数（xyz 是世界坐标，速度是米/秒）
目标x = 44
目标y = 0      # 0 表示"自动用地表高度 + 6 米"
目标z = 128
速度 = 4

# 传感器：pos vel cell yaw energy thrust blocks[5][5] blocks3[5][5][5] heights[5][5] here enemies orders
# 控制：set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后) drill(True) laser(x,y,z) laser_off() shoot(x,y,z)

def start():
    print("飞飞启动，地面高度 ", heights[2][2])

def loop():
    # 1) 高度：目标高度 = 地表上方 6 米（目标y 给了就按目标y）
    高度 = heights[2][2] + 6
    if 目标y > 0:
        高度 = 目标y
    if len(orders) > 0:
        高度 = orders[0].y + 2.5
    set_lift(0.585 + (高度 - pos.y) * 0.2 - vel.y * 0.12)

    # 2) 有标记指令就去最近的标记点，没有就去目标点
    要去x = 目标x
    要去z = 目标z
    距离 = ((目标x - pos.x) ** 2 + (目标z - pos.z) ** 2) ** 0.5
    if len(orders) > 0:
        单 = orders[0]
        要去x = 单.x + 0.5
        要去z = 单.z + 0.5
        距离 = 单.dist

    # 3) 朝要去的地方飞：喷口偏转产生水平推力，再按速度差修正
    想x = 0
    想z = 0
    if 距离 > 1.5:
        想x = (要去x - pos.x) / 距离 * 速度
        想z = (要去z - pos.z) / 距离 * 速度
    set_tilt(max(-1, min(1, (想x - vel.x) * 0.3)), max(-1, min(1, (想z - vel.z) * 0.3)))
    set_rcs(0, -vel.z * 0.2)

    # 4) 到了标记点就干活：挖掘用钻头 + 激光，别的先不动
    if len(orders) > 0 and 距离 < 3:
        单 = orders[0]
        if 单.action == "mine":
            drill(True)
            laser(单.x + 0.5, 单.y + 0.5, 单.z + 0.5)
        else:
            drill(False)
            laser_off()
    else:
        drill(False)
        laser_off()

    # 5) 看到敌人就打：15 米内开炮，5 米内再加激光
    if len(enemies) > 0:
        敌 = enemies[0]
        if 敌.dist <= 15:
            shoot(敌.x, 敌.y, 敌.z)
        if 敌.dist <= 5:
            laser(敌.x, 敌.y, 敌.z)
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
