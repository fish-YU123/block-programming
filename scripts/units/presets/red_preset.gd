extends RefCounted
## 红方无人机 的预设玩家代码（纯字符串，给代码面板 / 新单位用）

const SOURCE := """# 红方无人机（脚本 AI）
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
