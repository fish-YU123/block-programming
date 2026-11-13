# 炮艇：血厚炮狠，负责正面推进
# 传感器：pos / vel / enemies / hp_ratio / energy_ratio / res

def start():
    print("炮艇出击")

def loop():
    地面 = heights[2][2]
    # 队友（指挥官）下的指令：优先执行
    if len(cmd) > 0:
        if cmd.action == "goto":
            set_velocity(max(-20, min(20, (cmd.x - pos.x) * 0.5)),
                         max(-20, min(20, (cmd.z - pos.z) * 0.5)))
            set_altitude(cmd.y)
            return
        if cmd.action == "attack":
            到 = cmd.x - pos.x
            偏 = cmd.z - pos.z
            if 到 * 到 + 偏 * 偏 > 400.0:
                set_velocity(max(-20, min(20, 到 * 0.5)), max(-20, min(20, 偏 * 0.5)))
            else:
                set_velocity(0.0, 0.0)
                shoot(cmd.x, cmd.y, cmd.z)
            return
        if cmd.action == "hold":
            set_velocity(0.0, 0.0)
            return
    if len(enemies) == 0:
        # 自己看不见敌人，但侦察机可能标过点：按标记去打
        if len(marks) > 0:
            标 = marks[0]
            set_altitude(max(地面 + 9.0, 标.y + 6.0))
            if 标.dist > 20.0:
                set_velocity(max(-18, min(18, (标.x - pos.x) * 0.9)),
                             max(-18, min(18, (标.z - pos.z) * 0.9)))
            else:
                set_velocity(0.0, 0.0)
                shoot(标.x, 标.y, 标.z)
            return
        # 完全没情报就压向地图中线
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
