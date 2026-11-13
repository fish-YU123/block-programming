# 飞飞（僚机）：听指挥 + 会自保 + 看到敌人就报点开打
# 传感器：pos / vel / hp_ratio / energy_ratio / enemies / marks / orders / cmd / allies / res / peace / t

def start():
    mem["上次报点"] = -99.0
    mem["状态"] = "待命"
    mem["待命方向"] = 1
    print("飞飞就位")

def loop():
    地面 = heights[2][2]

    # 1) 电量见底：先回出生点上空省电悬停
    if energy_ratio < 0.2:
        set_velocity(0.0, 0.0)
        set_altitude(地面 + 4.0)
        drill(False)
        laser_off()
        return

    # 2) 玩家标的活优先（虚影标记）
    if len(orders) > 0:
        单 = orders[0]
        if 单.dist > 3.0:
            set_velocity(max(-14.0, min(14.0, (单.x - pos.x) * 0.9)),
                         max(-14.0, min(14.0, (单.z - pos.z) * 0.9)))
            set_altitude(float(单.y) + 3.0)
            return
        set_velocity(0.0, 0.0)
        if 单.action == "mine":
            drill(True)
            laser(单.x + 0.5, 单.y + 0.5, 单.z + 0.5)
        elif 单.action == "place":
            place(单.id, 单.x, 单.y, 单.z)
        return

    # 3) 指挥官/队友下的指令优先执行
    if len(cmd) > 0:
        if cmd.action == "goto":
            set_velocity(max(-14.0, min(14.0, (cmd.x - pos.x) * 0.6)),
                         max(-14.0, min(14.0, (cmd.z - pos.z) * 0.6)))
            set_altitude(cmd.y)
            return
        if cmd.action == "hold":
            set_velocity(0.0, 0.0)
            set_altitude(cmd.y)
            return
        if cmd.action == "attack":
            到 = cmd.x - pos.x
            偏 = cmd.z - pos.z
            if 到 * 到 + 偏 * 偏 > 100.0:
                set_velocity(max(-16.0, min(16.0, 到 * 0.8)), max(-16.0, min(16.0, 偏 * 0.8)))
                set_altitude(max(地面 + 6.0, cmd.y))
            else:
                set_velocity(0.0, 0.0)
                laser(cmd.x, cmd.y, cmd.z)
                shoot(cmd.x, cmd.y, cmd.z)
            return

    # 4) 有敌人：每 6 秒报一次点，然后贴着打
    if len(enemies) > 0:
        敌 = enemies[0]
        if t - mem["上次报点"] > 6.0:
            mark(敌.x, 敌.y, 敌.z, "敌人")
            team_set("敌情", len(enemies))
            mem["上次报点"] = t
        # 残血又离得远：先拉开
        if hp_ratio < 0.25 and 敌.dist > 6.0:
            set_velocity(-14.0, 10.0)
            set_altitude(地面 + 12.0)
            return
        set_altitude(max(地面 + 6.0, 敌.y))
        if 敌.dist > 5.0:
            set_velocity(max(-18.0, min(18.0, (敌.x - pos.x) * 1.0)),
                         max(-18.0, min(18.0, (敌.z - pos.z) * 1.0)))
        else:
            set_velocity(0.0, 0.0)
            drill(True)
            laser(敌.x, 敌.y, 敌.z)
        if 敌.dist <= 15.0:
            shoot(敌.x, 敌.y + 0.3, 敌.z)
        return

    # 5) 没敌人：去队友报的标记点看看
    if len(marks) > 0:
        标 = marks[0]
        if 标.dist > 8.0:
            set_velocity(max(-16.0, min(16.0, (标.x - pos.x) * 0.9)),
                         max(-16.0, min(16.0, (标.z - pos.z) * 0.9)))
            set_altitude(地面 + 9.0)
        else:
            set_velocity(0.0, 0.0)
            set_altitude(标.y + 6.0)
        return

    # 6) 完全没事：往中线集合（和指挥官一起压上去，别缩在家里）
    if pos.x < 118.0:
        set_velocity(16.0, 0.0)
    elif pos.x > 138.0:
        set_velocity(-16.0, 0.0)
    else:
        # 到中线了就在原地小幅巡逻，等敌情或队友的标记
        if mem["待命方向"] > 0:
            set_velocity(0.0, 8.0)
        else:
            set_velocity(0.0, -8.0)
        if pos.z > 140.0:
            mem["待命方向"] = -1
        if pos.z < 116.0:
            mem["待命方向"] = 1
    set_altitude(地面 + 9.0)
    drill(False)
    laser_off()
