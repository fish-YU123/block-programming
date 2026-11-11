extends RefCounted
## 钻地机：钻头超长，负责挖地道和矿脉

const SOURCE := """# 钻地机：贴着地面往前钻
# 传感器：pos / vel / orders / ore

def start():
    print("钻地机启动")

def loop():
    地面 = heights[2][2]
    if len(orders) > 0:
        单 = orders[0]
        if 单.dist > 2.5:
            set_velocity(max(-14, min(14, (单.x - pos.x) * 1.5)),
                         max(-14, min(14, (单.z - pos.z) * 1.5)))
            set_altitude(单.y + 2.0)
            return
        drill(True)
        laser(单.x + 0.5, 单.y + 0.5, 单.z + 0.5)
        set_velocity(0.0, 0.0)
        return
    # 没活干就朝对面矿脉方向慢慢钻
    set_velocity(6.0 if pos.x < 128 else -6.0, 0.0)
    set_altitude(地面 + 2.5)
    drill(True)
"""
