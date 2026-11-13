# 自爆无人机
# 传感器：pos / vel / enemies

def start():
    print("自爆无人机出发")

def loop():
    地面 = heights[2][2]
    if len(enemies) == 0:
        if pos.x < 128:
            set_velocity(20.0, 0.0)
        else:
            set_velocity(-20.0, 0.0)
        set_altitude(地面 + 8.0)
        return
    敌 = enemies[0]
    set_velocity(max(-26, min(26, (敌.x - pos.x) * 2.0)),
                 max(-26, min(26, (敌.z - pos.z) * 2.0)))
    if 敌.y > 地面 + 5.0:
        set_altitude(敌.y)
    else:
        set_altitude(地面 + 5.0)
