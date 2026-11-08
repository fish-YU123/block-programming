extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）

const FLYER_SOURCE := """# 飞飞：自动悬停
# 传感器：pos / vel / energy / yaw / blocks[5][5] / heights[5][5] / here
# 控制：set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后) drill(开关)
目标高度 = heights[2][2] + 6

while True:
    # 高度：按误差和垂直速度调升力
    误差 = 目标高度 - pos.y
    set_lift(0.55 + 误差 * 0.08 - vel.y * 0.06)
    # 位置：用 RCS / 矢量喷口抵消漂移，悬停在原地
    set_rcs(0, -vel.z * 0.6)
    set_tilt(0, -vel.x * 0.4)
    drill(False)
"""
