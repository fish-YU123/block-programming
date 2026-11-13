# 维修无人机：贴身修血
# 传感器：pos / vel / enemies / hp_ratio

def start():
    print("维修无人机就位")

def loop():
    地面 = heights[2][2]
    if len(enemies) > 0 and enemies[0].dist < 10.0:
        # 有敌人就先撤
        if pos.x < 128:
            set_velocity(-14.0, 0.0)
        else:
            set_velocity(14.0, 0.0)
    else:
        set_velocity(0.0, 0.0)
    set_altitude(地面 + 7.0)
