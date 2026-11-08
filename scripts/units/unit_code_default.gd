extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）

const FLYER_SOURCE := """# 飞飞：自动悬停
# 传感器：pos / vel / energy / yaw / blocks[5][5] / heights[5][5] / here
# 控制：set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后) drill(开关)
目标高度 = heights[2][2] + 6

while True:
    # 简单比例控制：按高度误差和垂直速度调升力
    误差 = 目标高度 - pos.y
    set_lift(0.55 + 误差 * 0.06 - vel.y * 0.05)
    # 慢速向前飞一点，然后停住（演示 RCS）
    if pos.z > 120:
        set_rcs(0, 0.35)
    else:
        set_rcs(0, -0.35)
    # 不钻孔
    drill(False)
"""
