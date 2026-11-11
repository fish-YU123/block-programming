extends RefCounted
## 布雷车：沿中线撒雷

const SOURCE := """# 布雷车：绕着中线来回撒雷
# 传感器：pos / vel / enemies

def start():
    print("布雷车开工")

def loop():
    # 在地图中线附近来回开，地雷会自动埋下去
    if pos.x < 120.0:
        set_rcs(0.0, 0.8)
    elif pos.x > 136.0:
        set_rcs(0.0, -0.8)
    else:
        set_rcs(1.0, 0.6)
    drill(False)
"""
