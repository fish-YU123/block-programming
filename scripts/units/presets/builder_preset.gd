extends RefCounted
## 建筑工的默认代码：照着玩家的虚影标记去放方块 / 挖方块

const SOURCE := """# 建筑工：按玩家的标记干活
# 传感器：pos / vel / orders / res / energy / heights[5][5] / t

def start():
    print("建筑工就位，手上能放方块（place）和钻头（drill）")

def loop():
    地面 = heights[2][2]
    set_altitude(地面 + 4.0)
    # 电量太低就回基地等充电
    if energy_ratio < 0.2:
        set_velocity(0.0, 0.0)
        return
    if len(orders) == 0:
        set_velocity(0.0, 0.0)
        drill(False)
        return
    单 = orders[0]
    if 单.dist > 3.0:
        # 还没到，先飞过去
        set_velocity(max(-14, min(14, (单.x - pos.x) * 1.2)),
                     max(-14, min(14, (单.z - pos.z) * 1.2)))
        set_altitude(单.y + 2.5)
        drill(False)
        return
    set_velocity(0.0, 0.0)
    if 单.action == "place":
        错 = place(单.id, 单.x, 单.y, 单.z)
        if 错 != "":
            print("放不了：", 错)
    elif 单.action == "mine":
        drill(True)
"""
