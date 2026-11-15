extends RefCounted
## 飞飞（僚机 v2）的预设玩家代码（纯字符串）。
## 运行时会优先读 data/presets/feifei.py；这份只是文件缺失时的兜底，内容与文件保持一致。

const SOURCE := """# 飞飞（僚机 v2）：报点 + 集火 + 风筝走位 + 能自保
# 传感器：pos vel hp hp_ratio energy_ratio enemies marks orders cmd allies team_mem res
#        peace t water submerged blocks3 heights below
# 控制：set_velocity set_altitude set_lift set_tilt set_rcs drill laser laser_off shoot
# 协同：mark team_set team_get command place build_here produce find_path

def start():
    mem["上次报点"] = -99.0
    mem["上次转向"] = 0.0
    mem["走位方向"] = 1
    mem["逃逸到"] = 0.0
    mem["状态"] = "待命"
    mem["待命方向"] = 1
    print("飞飞就位：", heights[2][2])

def 回家():
    if team == 0:
        家x = 34.0
    else:
        家x = 221.0
    return 家x

def 找目标():
    最好 = enemies[0]
    最少血 = 最好.hp
    for 每个 in enemies:
        if 每个.dist < 22.0 and 每个.hp < 最少血:
            最好 = 每个
            最少血 = 每个.hp
    return 最好

def 贴到(目标x, 目标z, 速度, 高度):
    set_velocity(max(-速度, min(速度, (目标x - pos.x) * 1.1)),
                 max(-速度, min(速度, (目标z - pos.z) * 1.1)))
    set_altitude(高度)

def 报点(敌):
    mark(敌.x, 敌.y, 敌.z, "敌人")
    team_set("敌情", 1)
    team_set("敌情x", 敌.x)
    team_set("敌情z", 敌.z)
    mem["上次报点"] = t

def loop():
    地面 = heights[2][2]
    高度 = 地面 + 9.0

    # 0) 掉进水里：先往上游，别淹死
    if water > 0.6:
        set_velocity(0.0, 0.0)
        set_altitude(pos.y + 4.0)
        drill(False)
        laser_off()
        return

    # 1) 电量告急：回自家上空省电（不干活、不追人）
    if energy_ratio < 0.25:
        set_velocity(0.0, 0.0)
        set_altitude(地面 + 5.0)
        drill(False)
        laser_off()
        return

    # 2) 玩家标的活最优先：挖 / 放
    if len(orders) > 0:
        单 = orders[0]
        if 单.dist > 3.5:
            贴到(单.x, 单.z, 15.0, float(单.y) + 3.0)
            return
        set_velocity(0.0, 0.0)
        if 单.action == "mine":
            drill(True)
            laser(单.x + 0.5, 单.y + 0.5, 单.z + 0.5)
        elif 单.action == "place":
            place(单.id, 单.x, 单.y, 单.z)
        return

    # 3) 队友/指挥官的指令
    if len(cmd) > 0:
        if cmd.action == "hold":
            set_velocity(0.0, 0.0)
            set_altitude(cmd.y + 4.0)
            return
        if cmd.action == "goto":
            if abs(cmd.x - pos.x) + abs(cmd.z - pos.z) > 2.0:
                贴到(cmd.x, cmd.z, 16.0, cmd.y)
            else:
                set_velocity(0.0, 0.0)
                set_altitude(cmd.y + 4.0)
            return
        if cmd.action == "attack":
            if abs(cmd.x - pos.x) + abs(cmd.z - pos.z) > 7.0:
                贴到(cmd.x, cmd.z, 17.0, max(地面 + 7.0, cmd.y))
            else:
                set_velocity(0.0, 0.0)
                laser(cmd.x, cmd.y, cmd.z)
                shoot(cmd.x, cmd.y, cmd.z)
            return

    # 4) 有敌人：报点 → 选最脆的 → 风筝打法
    if len(enemies) > 0:
        敌 = 找目标()
        if t - mem["上次报点"] > 5.0:
            报点(敌)
        高度 = max(地面 + 6.0, 敌.y + 1.0)

        # 残血：先拉出激光射程（8 格）之外，边退边打
        if hp_ratio < 0.35:
            贴到(回家(), 128.0, 17.0, 地面 + 12.0)
            if 敌.dist <= 8.0:
                laser(敌.x, 敌.y, 敌.z)
            return

        # 主循环：4~7 格是理想射程（激光 8，炮 15）
        if 敌.dist > 7.0:
            贴到(敌.x, 敌.z, 18.0, 高度)
        elif 敌.dist < 3.0:
            # 太近会被钻头/自爆糊脸：侧向拉开
            if t - mem["上次转向"] > 1.2:
                mem["走位方向"] = -mem["走位方向"]
                mem["上次转向"] = t
            set_velocity(0.0, 11.0 * mem["走位方向"])
            set_altitude(高度 + 2.0)
        else:
            # 射程内：横向绕圈，别悬停成靶子
            if t - mem["上次转向"] > 1.5:
                mem["走位方向"] = -mem["走位方向"]
                mem["上次转向"] = t
            set_velocity(-4.0, 7.0 * mem["走位方向"])
            set_altitude(高度)

        if 敌.dist <= 8.0:
            laser(敌.x, 敌.y, 敌.z)
        else:
            laser_off()
        if 敌.dist <= 15.0:
            shoot(敌.x, 敌.y + 0.4, 敌.z)
        if 敌.dist <= 3.2:
            drill(True)
        else:
            drill(False)
        return

    # 5) 没敌人：去队友报的点看看，但别一个人冲进对面家
    if len(marks) > 0:
        标 = marks[0]
        if 标.dist > 9.0:
            贴到(标.x, 标.z, 16.0, 地面 + 9.0)
        else:
            set_velocity(0.0, 0.0)
            set_altitude(标.y + 6.0)
        drill(False)
        laser_off()
        return

    # 6) 完全没事：往中线集合；队友少就靠家一点，人多再压上去
    队友 = len(allies) + 1
    if team == 0:
        if 队友 < 3:
            线 = 96.0
        else:
            线 = 126.0
        方向 = 1.0
    else:
        if 队友 < 3:
            线 = 160.0
        else:
            线 = 130.0
        方向 = -1.0

    偏移 = pos.x - 线
    if 偏移 * 方向 < -6.0:
        # 还没到集合线：朝它飞（蓝方往右、红方往左）
        set_velocity(16.0 * 方向, 0.0)
    elif 偏移 * 方向 > 6.0:
        # 冲过头了：退回来
        set_velocity(-16.0 * 方向, 0.0)
    else:
        # 在线上：沿 z 小幅巡逻等敌情
        if mem["待命方向"] > 0:
            set_velocity(0.0, 8.0)
        else:
            set_velocity(0.0, -8.0)
        if pos.z > 140.0:
            mem["待命方向"] = -1
        if pos.z < 116.0:
            mem["待命方向"] = 1

    set_altitude(高度)
    drill(False)
    laser_off()
"""
