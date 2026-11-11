extends RefCounted
## 平台无人机：空中供电平台

const SOURCE := """# 平台无人机：待在队伍中间给所有人回电
# 传感器：pos / vel / enemies

def start():
    print("平台无人机升空")

def loop():
    地面 = heights[2][2]
    if len(enemies) > 0 and enemies[0].dist < 12.0:
        if pos.x < 128:
            set_velocity(-12.0, 0.0)
        else:
            set_velocity(12.0, 0.0)
    else:
        set_velocity(0.0, 0.0)
    set_altitude(地面 + 16.0)
"""
