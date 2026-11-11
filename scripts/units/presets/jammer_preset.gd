extends RefCounted
## 干扰机：飞到敌方阵地上空压制

const SOURCE := """# 干扰机：抵近敌方，压制他们的代码执行速度
# 传感器：pos / vel / enemies

def start():
    print("干扰机上线")

def loop():
    地面 = heights[2][2]
    if len(enemies) == 0:
        if pos.x < 128:
            set_velocity(18.0, 0.0)
        else:
            set_velocity(-18.0, 0.0)
        set_altitude(地面 + 12.0)
        return
    敌 = enemies[0]
    if 敌.dist > 14.0:
        set_velocity(max(-18, min(18, 敌.x - pos.x)), max(-18, min(18, 敌.z - pos.z)))
    else:
        set_velocity(0.0, 0.0)
    if 敌.y + 5.0 > 地面 + 10.0:
        set_altitude(敌.y + 5.0)
    else:
        set_altitude(地面 + 10.0)
"""
