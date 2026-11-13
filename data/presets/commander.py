# 指挥官 AI（蓝红双方共用，按 team 自动分左右）：开局造矿机 / 组装厂 / 充电站，靠经济滚雪球压死对面
# start() 跑一次；loop() 每秒 60 行预算里反复跑
# 传感器：pos vel energy hp hp_ratio team peace res enemies below heights blocks
# 指令：build_here(建筑id) 在自己旁边找平地盖；build(建筑id, x, y, z) 指定格子
#       set_velocity(x, z) set_altitude(y) drill laser shoot set_tilt set_rcs

def start():
    if team == 0:
        print("蓝方指挥官上线，地面高度 ", heights[2][2])
    else:
        print("红方指挥官上线，地面高度 ", heights[2][2])
    mem["已建"] = 0
    mem["等"] = 0.0
    mem["方向"] = 1
    mem["家x"] = pos.x
    mem["上次见敌"] = 0.0
    mem["养伤"] = 0
    mem["家z"] = pos.z

def loop():
    # 指挥官只在发育期搞生产；发育期一结束就亲自带兵压上
    if leader == 1 and peace > 0:
        建设()
    elif peace > 0:
        建设()
    else:
        进攻()

def 到(x, z, 速度, 高度):
    差x = x - pos.x
    差z = z - pos.z
    set_velocity(max(-速度, min(速度, 差x * 1.2)), max(-速度, min(速度, 差z * 1.2)))
    set_altitude(高度)

def 建设():
    # 待在自己基地上空悬停，专心盖楼（挖矿交给矿机，省电也省心）
    地面 = heights[2][2]
    set_velocity(0.0, 0.0)
    set_altitude(地面 + 5.0)
    # 基地被敌人摸到就先打回去（指挥官也会自卫）
    if len(enemies) > 0:
        if enemies[0].dist <= 12:
            drill(True)
            laser(enemies[0].x, enemies[0].y, enemies[0].z)
            shoot(enemies[0].x, enemies[0].y, enemies[0].z)
            return
    drill(False)
    laser_off()
    # 只有指挥官负责盖楼，其他单位专心打仗（否则每个单位都乱花资源）
    if leader == 0:
        return
    # 上一栋还在施工（10 秒）就先别动，让建筑一栋一栋拔地而起
    if t < mem["等"]:
        return
    # 建造顺序：矿机 → 发电站 → 储能站 → 组装厂 → 充电站 → 炮塔 → (攒钱) 扩张
    if mem["已建"] == 0:
        if res["copper"] >= 20 and res["coal"] >= 10:
            if build_here("miner") == "":
                mem["已建"] = 1
                mem["等"] = t + 11.0
                print("矿机就位")
    elif mem["已建"] == 1:
        if res["copper"] >= 35 and res["iron"] >= 15:
            if build_here("powerplant") == "":
                mem["已建"] = 2
                mem["等"] = t + 11.0
                print("发电站就位")
    elif mem["已建"] == 2:
        if res["copper"] >= 40 and res["coal"] >= 30:
            if build_here("factory") == "":
                mem["已建"] = 3
                mem["等"] = t + 11.0
                print("组装厂一号就位")
    elif mem["已建"] == 3:
        # 维修厂放在很前面：残血部队能真的回家修，对局才会拉锯起来
        if res["copper"] >= 28 and res["iron"] >= 10:
            if build_here("repairbay") == "":
                mem["已建"] = 4
                mem["等"] = t + 11.0
                print("维修厂就位")
        elif res["copper"] >= 25 and res["coal"] >= 15:
            if build_here("battery") == "":
                mem["已建"] = 4
                mem["等"] = t + 11.0
                print("储能站就位")
    elif mem["已建"] == 4:
        # 再补储能站/充电站，让部队打久了能回来补电
        if res["copper"] >= 25 and res["coal"] >= 15:
            if build_here("battery") == "":
                mem["已建"] = 5
                mem["等"] = t + 11.0
                print("储能站就位")
        elif res["copper"] >= 30 and res["iron"] >= 10:
            if build_here("charger") == "":
                mem["已建"] = 5
                mem["等"] = t + 11.0
                print("充电站就位")
        elif res["copper"] >= 20 and res["coal"] >= 10:
            if build_here("miner") == "":
                mem["已建"] = 5
                mem["等"] = t + 11.0
                print("二号矿机就位")
        elif res["copper"] >= 40 and res["coal"] >= 30:
            if build_here("factory") == "":
                mem["已建"] = 5
                mem["等"] = t + 11.0
                print("组装厂二号就位")
    else:
        # 铜优先留给定产；攒够了再补炮塔防偷家
        if res["copper"] >= 60 and res["iron"] >= 25:
            if build_here("turret") == "":
                mem["等"] = t + 11.0
                print("炮塔就位")
        elif res["copper"] >= 30 and res["iron"] >= 12:
            if build_here("radar") == "":
                mem["等"] = t + 11.0
                print("雷达站就位")
        elif res["copper"] >= 28 and res["iron"] >= 10:
            if build_here("repairbay") == "":
                mem["等"] = t + 11.0
                print("维修厂就位")
        elif res["copper"] >= 200 and res["coal"] >= 80:
            if build_here("factory") == "":
                mem["等"] = t + 11.0
                print("再盖一座组装厂")
        elif res["copper"] >= 150 and res["iron"] >= 10:
            if build_here("charger") == "":
                mem["等"] = t + 11.0
                print("充电站就位")

def 进攻():
    地面 = heights[2][2]
    # 残血且家里有维修厂、也有电，才回去修；没有维修厂就继续打（回家干等只会僵住）
    if hp_ratio < 0.35 and res["repair"] > 0 and sudden == 0:
        mem["养伤"] = 1
    if mem["养伤"] == 1:
        if hp_ratio > 0.85 and abs(pos.x - mem["家x"]) < 16.0:
            mem["养伤"] = 0
        else:
            到(mem["家x"], mem["家z"], 22.0, 地面 + 6.0)
            drill(False)
            laser_off()
            return
    # 电量低了先回基地充电站附近补电（不然飞到一半没电会掉地上等死）
    if energy_ratio < 0.35:
        drill(False)
        laser_off()
        到(mem["家x"], mem["家z"], 18.0, 地面 + 5.0)
        return
    # 跑到地图外面（或者掉得太低）先自己飞回来
    if pos.x < 2 or pos.x > 254 or pos.y < 9:
        到(mem["家x"], mem["家z"], 20.0, 地面 + 8.0)
        return
    if len(enemies) == 0:
        # 雷达里没有敌人：都往地图正中间的一个点集合（两边阈值必须重叠，否则
        # 会在中线两侧各自悬停、相距超过雷达半径，永远打不起来）
        if t - mem["上次见敌"] > 25.0:
            # 25 秒没见到人，说明对面缩家了：直接朝敌方基地方向压过去
            if team == 0:
                到(min(240.0, pos.x + 30.0), 128.0, 26.0, 地面 + 9.0)
            else:
                到(max(16.0, pos.x - 30.0), 128.0, 26.0, 地面 + 9.0)
        elif pos.x < 124.0 or pos.x > 132.0:
            到(128.0, 128.0, 24.0, 地面 + 9.0)
        else:
            set_velocity(0.0, 0.0)
            set_altitude(地面 + 9.0)
        drill(False)
        laser_off()
        return
    mem["上次见敌"] = t
    敌 = enemies[0]
    # 指挥官用 command 直接调度队友：让非指挥官的兵种一起集火这个目标
    if leader == 1:
        for 友 in allies:
            if 友.type != "feifei":
                command(友.uid, "attack", 敌.x, 敌.y, 敌.z)
    # 追击时别贴地飞（贴着山会卡住），至少保持地面以上 7 米
    追击高度 = max(地面 + 7.0, 敌.y + 1.0)
    if 敌.dist > 2.5:
        到(敌.x, 敌.z, 26.0, 追击高度)
        drill(False)
        laser_off()
    else:
        set_velocity(0.0, 0.0)
        set_altitude(敌.y)
        drill(True)
        laser(敌.x, 敌.y, 敌.z)
    if 敌.dist <= 15:
        shoot(敌.x, 敌.y + 0.2, 敌.z)

