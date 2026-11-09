extends RefCounted
## 预设单位的默认玩家代码（新建单位、示例按钮都用它）
##
## 每个单位支持两个固定函数：
##   def start():  开局（或点「应用」）时跑一次
##   def loop():   之后一直反复跑
## 两个都不写的话，整段代码会从头循环执行（老写法仍然有效）。

const FLYER_SOURCE := """# 飞飞：默认行为（自己的手写控制，寻路用 find_path 拿航路）
# 改下面这几个数就能让它去别的地方
目标x = 44
目标y = 0      # 0 表示"自动用地表高度 + 6 米"
目标z = 128
速度 = 6

# 传感器：pos vel cell yaw energy thrust moving blocks[5][5] blocks3[5][5][5] heights[5][5] here enemies orders
# 可用：find_path(x,y,z) 返回航路列表；go_to(x,y,z) 一行版自动驾驶
#       set_velocity(水平x速度, 水平z速度) set_altitude(高度) —— 每帧自动闭环，不会抖
#       set_lift(0~1) set_tilt(前后, 左右) set_rcs(转向, 前后)
#       drill(True) laser(x,y,z) laser_off() shoot(x,y,z)

def start():
    print("飞飞启动，地面高度 ", heights[2][2])

def loop():
    # 1) 决定去哪：有玩家的标记就去最近的标记，否则去目标点
    去x = 目标x
    去y = 目标y
    去z = 目标z
    if len(orders) > 0:
        去x = orders[0].x + 0.5
        去y = orders[0].y + 2.5
        去z = orders[0].z + 0.5
    elif 目标y == 0:
        去y = heights[2][2] + 6

    # 2) A* 算航路，自己朝航路上的第一个点飞
    航路 = find_path(去x, 去y, 去z)
    点x = 去x
    点y = 去y
    点z = 去z
    if len(航路) > 0:
        点x = 航路[0].x
        点y = 航路[0].y
        点z = 航路[0].z
    差x = 点x - pos.x
    差z = 点z - pos.z
    距离 = (差x * 差x + 差z * 差z) ** 0.5
    # 到的了这个点就按巡航速度冲，快到了就减速
    想x = max(-速度, min(速度, 差x * 1.5))
    想z = max(-速度, min(速度, 差z * 1.5))
    # 3) 下指令：想要的速度 + 想要的高度（引擎每帧自己闭环，所以不抖）
    set_velocity(想x, 想z)
    set_altitude(点y)

    # 5) 到标记旁边就干活：挖掘用钻头 + 激光
    干活 = len(orders) > 0 and orders[0].dist < 3
    drill(干活 and orders[0].action == "mine")
    if 干活 and orders[0].action == "mine":
        laser(orders[0].x + 0.5, orders[0].y + 0.5, orders[0].z + 0.5)
    else:
        laser_off()

    # 6) 看到敌人就打：15 米内开炮，5 米内再加激光
    if len(enemies) > 0:
        if enemies[0].dist <= 15:
            shoot(enemies[0].x, enemies[0].y, enemies[0].z)
        if enemies[0].dist <= 5:
            laser(enemies[0].x, enemies[0].y, enemies[0].z)
"""

## 红方无人机：追最近的敌方单位，贴上去开钻
const RED_SOURCE := """# 红方无人机（脚本 AI）
def loop():
    目标高度 = heights[2][2] + 8
    期望速度 = 0.0
    距离 = 999.0
    if len(enemies) > 0:
        敌 = enemies[0]
        距离 = 敌.x - pos.x
        期望速度 = max(-7, min(7, 距离 * 1.2))
        if abs(距离) < 1.5:
            期望速度 = 0
    误差 = 目标高度 - pos.y
    set_lift(0.57 + 误差 * 0.15 - vel.y * 0.1)
    set_rcs(0, -vel.z * 0.6)
    set_tilt(max(-1, min(1, (vel.x - 期望速度) * 0.08)), 0)
    if len(enemies) > 0:
        纵向 = 敌.y - pos.y
        drill(abs(距离) < 2.5 and abs(纵向) < 2.5)
    else:
        drill(False)
"""

## 对局用的格斗预设：自动找最近敌人，靠近后炮击 / 激光 / 钻头齐上
const FIGHTER_SOURCE := """# 飞飞对战 AI：发育期自己挖矿，开打后缠斗 / 拉距离炮击 / 贴身激光
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
"""


## 车车（地面车）的默认代码：朝目标开过去，到了就钻
const COMMANDER_SOURCE := """# 指挥官 AI（蓝红双方共用，按 team 自动分左右）：开局造矿机 / 组装厂 / 充电站，靠经济滚雪球压死对面
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

def loop():
    if peace > 0:
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
    drill(False)
    laser_off()
    # 只有指挥官负责盖楼，其他单位专心打仗（否则每个单位都乱花资源）
    if leader == 0:
        return
    # 上一栋还在施工（10 秒）就先别动，让建筑一栋一栋拔地而起
    if t < mem["等"]:
        return
    # 建造顺序：矿机 → 两座组装厂 → (攒钱) → 再加组装厂 / 充电站
    if mem["已建"] == 0:
        if res["copper"] >= 20 and res["coal"] >= 10:
            if build_here("miner") == "":
                mem["已建"] = 1
                mem["等"] = t + 11.0
                print("矿机就位")
    elif mem["已建"] == 1:
        if res["copper"] >= 40 and res["coal"] >= 30:
            if build_here("factory") == "":
                mem["已建"] = 2
                mem["等"] = t + 11.0
                print("组装厂一号就位")
    elif mem["已建"] == 2:
        if res["copper"] >= 40 and res["coal"] >= 30:
            if build_here("factory") == "":
                mem["已建"] = 3
                mem["等"] = t + 11.0
                print("组装厂二号就位，两座一起造飞飞")
    else:
        # 铜优先留给定产，攒够了才盖充电站 / 新工厂
        if res["copper"] >= 200 and res["coal"] >= 80:
            if build_here("factory") == "":
                mem["等"] = t + 11.0
                print("再盖一座组装厂")
        elif res["copper"] >= 150 and res["iron"] >= 10:
            if build_here("charger") == "":
                mem["等"] = t + 11.0
                print("充电站就位")

def 进攻():
    地面 = heights[2][2]
    if len(enemies) == 0:
        if pos.x < 128:
            到(pos.x + 24.0, pos.z, 26.0, 地面 + 9.0)
        else:
            到(pos.x - 24.0, pos.z, 26.0, 地面 + 9.0)
        drill(False)
        laser_off()
        return
    敌 = enemies[0]
    if 敌.dist > 8:
        到(敌.x, 敌.z, 26.0, 敌.y + 1.0)
        drill(False)
        laser_off()
    else:
        set_velocity(0.0, 0.0)
        set_altitude(敌.y)
        drill(True)
        laser(敌.x, 敌.y, 敌.z)
    if 敌.dist <= 15:
        shoot(敌.x, 敌.y + 0.2, 敌.z)

"""
const ROVER_SOURCE := """# 车车：地面工程车
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
