extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）
##
## 每个单位支持两个固定函数：
##   def start():  开局（或点「应用」）时跑一次
##   def loop():   之后一直反复跑
## 两个都不写的话，整段代码会从头循环执行（老写法仍然有效）。

const FLYER_SOURCE := """# 飞飞：起飞悬停
# 传感器：pos vel cell yaw energy thrust blocks[5][5] heights[5][5] here enemies
# 控制：set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后) drill(True/False)

def start():
    print("飞飞启动，地面高度 ", heights[2][2])

def loop():
    # 先算目标：地表上方 8 米
    目标高度 = heights[2][2] + 8
    误差 = 目标高度 - pos.y
    # 高了少推、低了多推，再减去上升速度做阻尼
    set_lift(0.57 + 误差 * 0.15 - vel.y * 0.1)
    # 前后/左右也做一点阻尼，别被风吹跑
    set_tilt(0, -vel.x * 0.4)
    set_rcs(0, -vel.z * 0.6)
    drill(False)
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
