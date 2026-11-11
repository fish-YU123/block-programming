extends RefCounted
## 炮艇的默认代码：远程炮火压制 + 追击

const SOURCE := """# 炮艇：血厚炮狠，负责正面推进
# 传感器：pos / vel / enemies / hp_ratio / energy_ratio / res

def start():
    print("炮艇出击")

def loop():
    地面 = heights[2][2]
    if len(enemies) == 0:
        # 没敌情就压向地图中线
        if pos.x < 118.0:
            set_velocity(14.0, 0.0)
        elif pos.x > 138.0:
            set_velocity(-14.0, 0.0)
        else:
            set_velocity(0.0, 0.0)
        set_altitude(地面 + 11.0)
        return
    敌 = enemies[0]
    set_altitude(max(地面 + 9.0, 敌.y + 2.0))
    if 敌.dist > 12.0:
        set_velocity(max(-18, min(18, (敌.x - pos.x) * 0.8)),
                     max(-18, min(18, (敌.z - pos.z) * 0.8)))
    else:
        set_velocity(0.0, 0.0)
    if 敌.dist <= 22.0:
        shoot(敌.x, 敌.y, 敌.z)
    if 敌.dist <= 8.0:
        laser(敌.x, 敌.y, 敌.z)
"""
