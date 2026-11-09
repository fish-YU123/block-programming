extends RefCounted
## 车车 的预设玩家代码（纯字符串，给代码面板 / 新单位用）

const SOURCE := """# 车车：地面工程车
def start():
    print("车车启动，地面高度 ", heights[2][2])

def loop():
    if len(orders) > 0:
        单 = orders[0]
        距离 = 单.dist
        if 距离 > 2.5:
            set_rcs(0, 0.8)          # 油门
        else:
            set_rcs(0, 0)
            if 单.action == "mine":
                drill(True)
                set_rcs(0, 0.2)
    else:
        set_rcs(0, 0)
"""
