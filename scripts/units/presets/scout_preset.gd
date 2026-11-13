extends RefCounted
## 侦察机的默认代码：高空绕圈巡逻，把敌方位置报给全队

const SOURCE := """# 侦察机：不打架，负责当眼睛
# 传感器：pos / vel / enemies / team / t / energy_ratio

def start():
    mem["方向"] = 1
    print("侦察机出发")

def loop():
    地面 = heights[2][2]
    高度 = 地面 + 22.0
    set_altitude(高度)
    # 沿着地图中部来回飞，把两边的情况都看一遍
    if pos.x > 210.0:
        mem["方向"] = -1
    if pos.x < 46.0:
        mem["方向"] = 1
    set_velocity(22.0 * mem["方向"], 4.0)
    # 看到敌人：把它的位置标给全队（队友的 marks 里会出现，炮艇就会去打）
    if len(enemies) > 0:
        敌 = enemies[0]
        mark(敌.x, 敌.y, 敌.z, "敌人")
        team_set("敌人数量", len(enemies))
    # 保持 25 米安全距离，别贴脸
    if len(enemies) > 0:
        if enemies[0].dist < 18.0:
            set_velocity(-16.0 * mem["方向"], 0.0)
"""
