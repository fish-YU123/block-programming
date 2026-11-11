extends RefCounted
## 货运飞飞的默认代码：给前线送电

const SOURCE := """# 货运飞飞：把自己身上的电输送给缺电的友军
# 传感器：pos / vel / enemies / energy / energy_ratio / res

def start():
    print("货运飞飞起飞，负责送电")

def loop():
    地面 = heights[2][2]
    # 自己电量低于 25% 就先回基地充电站附近充电
    if energy_ratio < 0.25:
        transfer(False)
        set_velocity(0.0, 0.0)
        set_altitude(地面 + 4.0)
        return
    # 有敌人时躲远一点
    if len(enemies) > 0 and enemies[0].dist < 12.0:
        transfer(False)
        if pos.x < 128:
            set_velocity(18.0, 0.0)
        else:
            set_velocity(-18.0, 0.0)
        set_altitude(地面 + 12.0)
        return
    # 否则开着输送，飞向地图中线附近找需要电的友军
    transfer(True)
    if pos.x < 110.0:
        set_velocity(16.0, 0.0)
    elif pos.x > 146.0:
        set_velocity(-16.0, 0.0)
    else:
        set_velocity(0.0, 0.0)
    set_altitude(地面 + 10.0)
"""
