extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）

const FLYER_SOURCE := """# 飞飞：自动悬停
# 传感器：pos / vel / energy / yaw / blocks[5][5] / heights[5][5] / here / enemies
# 控制：set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后) drill(开关)
目标高度 = heights[2][2] + 8

while True:
    # 高度：按误差和垂直速度调升力
    误差 = 目标高度 - pos.y
    set_lift(0.57 + 误差 * 0.15 - vel.y * 0.1)
    # 位置：用 RCS / 矢量喷口抵消漂移，悬停在原地
    set_rcs(0, -vel.z * 0.6)
    set_tilt(0, -vel.x * 0.4)
    drill(False)
"""

## 红方无人机：追最近的敌方单位（连高度一起追），贴上去开钻
const RED_SOURCE := """# 红方无人机（脚本 AI）
while True:
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
