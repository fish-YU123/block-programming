# 飞飞对战 AI：发育期自己挖矿，开打后缠斗 / 拉距离炮击 / 贴身激光
# 结构：start() 跑一次；loop() 每秒 60 行预算里反复跑
# 传感器：pos vel cell yaw energy hp hp_ratio team peace enemies orders blocks blocks3 heights here
# 指令：set_lift set_tilt set_rcs drill laser laser_off shoot set_velocity set_altitude find_path go_to stop

def start():
    print("飞飞就位，地面高度 ", heights[2][2])
    mem["阶段"] = "发育"
    mem["挖到的矿"] = 0
    mem["游走"] = 0
    mem["方向"] = 1
    mem["上次血量"] = hp

def loop():
    if peace > 0:
        发育()
    else:
        战斗()

def 到(x, z, 速度, 高度):
    差x = x - pos.x
    差z = z - pos.z
    限x = max(-速度, min(速度, 差x * 1.2))
    限z = max(-速度, min(速度, 差z * 1.2))
    set_velocity(限x, 限z)
    set_altitude(高度)

def 发育():
    # 在自己半场低空来回巡逻，顺便用激光把地面往下扫（挖到矿就有资源进账）
    地面 = heights[2][2]
    if team == 0:
        if pos.x > 88:
            mem["方向"] = -1
        if pos.x < 42:
            mem["方向"] = 1
    else:
        if pos.x < 168:
            mem["方向"] = 1
        if pos.x > 214:
            mem["方向"] = -1
    到(pos.x + mem["方向"] * 12, pos.z, 9.0, 地面 + 6.0)
    drill(False)
    laser(cell.x + 0.5, cell.y - 4.0, cell.z + 0.5)

def 血量告急():
    return hp_ratio < 0.35

def 战斗():
    地面 = heights[2][2]
    if len(enemies) == 0:
        # 雷达里没敌人：一边升空一边往对面半场推
        if pos.x < 128:
            到(pos.x + 20.0, pos.z, 26.0, 地面 + 9.0)
        else:
            到(pos.x - 20.0, pos.z, 26.0, 地面 + 9.0)
        drill(False)
        laser_off()
        return
    敌 = enemies[0]
    距离 = 敌.dist
    mem["阶段"] = "交战"
    # 简单粗暴：贴上去打。远就加速冲，近了就钻头 + 激光 + 炮一起上
    if 距离 > 8:
        到(敌.x, 敌.z, 24.0, 敌.y + 1.5)
        drill(False)
        laser_off()
    else:
        set_velocity(0.0, 0.0)
        set_altitude(敌.y)
        drill(True)
        laser(敌.x, 敌.y, 敌.z)
    if 距离 <= 15:
        shoot(敌.x, 敌.y, 敌.z)

def 高度目标():
    return heights[2][2] + 8.0
