extends RefCounted
## 把一个预设单位和它的沙箱虚拟机连起来：每帧注入传感器读数、按预算跑代码、
## 把代码写出的控制量交给单位，并把错误/日志带回给 UI。

const PyVM = preload("res://scripts/lang/py_vm.gd")

## 每个单位每秒可执行的语句数（控制中心的大脑节奏）
const LINES_PER_SECOND := 60.0
## 单帧最多推进几条语句，避免卡帧
const MAX_STEPS_PER_FRAME := 4
const MAX_LOGS := 40

var unit: Node3D
var source := ""
var revision := 0
var logs: Array = []

var enemies: Array = []
var orders: Array = []
## 建筑接口（由 main 注入）：func(id: String, cell: Vector3i) -> String / func(id: String) -> String
var build_provider: Callable = Callable()
var build_here_provider: Callable = Callable()
var place_provider: Callable = Callable()
## 开局发育时间剩余秒数（>0 时双方不能攻击）
var peace_left := 0.0
## 全队资源（字典，由 main 每帧喂进来）
var resources: Dictionary = {}
## 是不是队伍里的"指挥官"（只有它会主动盖建筑，避免每个单位都乱花资源）
var is_leader := false

var _vm: PyVM
## 一"段"代码执行期间的列表类传感器快照（敌方/标记/雷达），
## 避免 60 行/秒的慢速执行里出现"上一行还在、下一行就空了"的竞态。
var _list_snapshot: Dictionary = {}
var _budget := 0.0
var _started := false
var _halted := false
var _last_error := ""


func bind(unit_node: Node3D, code: String, code_revision: int) -> void:
	unit = unit_node
	source = code
	revision = code_revision
	_budget = 0.0
	_halted = false
	_last_error = ""
	logs = []
	_vm = PyVM.new()
	_wire_path_provider()
	_list_snapshot = {}
	_vm.load_source(source)
	if _vm.finished and _vm.error != "":
		_halted = true
		_last_error = _vm.error
	_apply_idle_controls()


## 由主场景每帧更新：视野内敌方单位（[{"x","y","z","type","hp","dist"}]，按距离排序）
func set_enemies(list: Array) -> void:
	enemies = list


## 由主场景每帧更新：玩家标记的指令（[{"x","y","z","action","id","dist"}]，按距离排序）
## 正下方最近的实心方块（给挖矿 AI 用，整数格，稳）
func _first_solid_below(u: Node, pos: Dictionary) -> Dictionary:
	var world = u.get("world")
	if world == null:
		return {}
	# 必须从枪口（机头前上方）往下打，才和激光实际命中的格子一致
	var from: Vector3 = u.muzzle_world()
	var hit: Dictionary = world.raycast(from, from + Vector3(0.0, -7.0, 0.0))
	if hit.is_empty():
		return {}
	var cell: Vector3i = hit["cell"]
	return {"x": cell.x, "y": cell.y, "z": cell.z}


## 在 5×5×5 的 blocks3 里找最近的矿（GDScript 里扫，别让 VM 自己循环 125 次）
func _nearest_ore(blocks3: Array, cell: Dictionary) -> Dictionary:
	if blocks3.is_empty():
		return {}
	var best: Dictionary = {}
	var best_d := 999.0
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			for dz in range(-2, 3):
				var layer: Array = blocks3[dx + 2]
				var column: Array = layer[dy + 2]
				var name := str(column[dz + 2])
				if name != "coal_ore" and name != "copper_ore" and name != "iron_ore" and name != "gold_ore":
					continue
				var d: float = absf(float(dx)) + absf(float(dy)) * 1.5 + absf(float(dz))
				if d < best_d:
					best_d = d
					best = {
						"x": int(cell["x"]) + dx,
						"y": int(cell["y"]) + dy,
						"z": int(cell["z"]) + dz,
						"name": name,
						"dist": d,
					}
	return best


func set_resources(value: Dictionary) -> void:
	resources = value


func set_peace(seconds: float) -> void:
	peace_left = seconds


func set_orders(list: Array) -> void:
	orders = list


func halted() -> bool:
	return _halted


func last_error() -> String:
	return _last_error


var _elapsed := 0.0  ## 这个单位开机以来过了多少秒（给 AI 计时用）

func tick(delta: float) -> void:
	if unit == null or _vm == null:
		return
	if _halted:
		_apply_idle_controls()
		unit.runtime_error = _last_error
		return
	_elapsed += delta
	_inject_sensors(false)
	_budget += delta * LINES_PER_SECOND
	var steps := mini(int(_budget), MAX_STEPS_PER_FRAME)
	for i in steps:
		_budget -= 1.0
		var result: Dictionary = _vm.step(1)
		if not bool(result.get("ok", true)):
			_halted = true
			_last_error = str(result.get("error", "运行时错误"))
			break
		var new_logs: Array = result.get("logs", [])
		if not new_logs.is_empty():
			logs.append_array(new_logs)
			while logs.size() > MAX_LOGS:
				logs.pop_front()
		if bool(result.get("done", false)):
			_advance()
	if _halted:
		_apply_idle_controls()
		unit.runtime_error = _last_error
		return
	var controls: Dictionary = _vm.state.get("controls", {})
	unit.controls = {
		"lift": float(controls.get("lift", 0.0)),
		"pitch": float(controls.get("pitch", 0.0)),
		"roll": float(controls.get("roll", 0.0)),
		"turn": float(controls.get("turn", 0.0)),
		"forward": float(controls.get("forward", 0.0)),
		"drill": bool(controls.get("drill", false)),
		"laser": bool(controls.get("laser", false)),
		"laser_x": float(controls.get("laser_x", 0.0)),
		"laser_y": float(controls.get("laser_y", 0.0)),
		"laser_z": float(controls.get("laser_z", 0.0)),
		"shoot": bool(controls.get("shoot", false)),
		"shoot_x": float(controls.get("shoot_x", 0.0)),
		"shoot_y": float(controls.get("shoot_y", 0.0)),
		"shoot_z": float(controls.get("shoot_z", 0.0)),
		"vel_mode": bool(controls.get("vel_mode", false)),
		"vx": float(controls.get("vx", 0.0)),
		"vz": float(controls.get("vz", 0.0)),
		"alt_mode": bool(controls.get("alt_mode", false)),
		"alt_target": float(controls.get("alt_target", 0.0)),
	}
	# 自动驾驶指令：go_to(x,y,z) / stop()
	var go := bool(controls.get("go", false))
	if go:
		unit.request_go(Vector3(
			float(controls.get("go_x", 0.0)),
			float(controls.get("go_y", 0.0)),
			float(controls.get("go_z", 0.0))
		))
	elif unit.has_goal:
		unit.clear_go()
	unit.runtime_error = ""
	unit.runtime_logs = logs


## 跑完一段后决定下一段跑什么：先 start（只跑一次），之后反复跑 loop；
## 两个函数都没写就回到老行为：整段代码从头再跑一遍（mem 保留）。
func _advance() -> void:
	if _vm.error != "":
		return
	# 每到一段代码的边界刷新一次列表快照，段内保持不变
	_inject_sensors(true)
	if not _started and _vm.has_function("start"):
		_started = true
		if _vm.call_function("start"):
			return
	_started = true
	if _vm.has_function("loop"):
		if _vm.call_function("loop"):
			return
	_vm.restart()


func _apply_idle_controls() -> void:
	unit.controls = {
		"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false,
		"laser": false, "laser_x": 0.0, "laser_y": 0.0, "laser_z": 0.0,
		"shoot": false, "shoot_x": 0.0, "shoot_y": 0.0, "shoot_z": 0.0,
	}
	unit.clear_go()
	unit.runtime_logs = logs


func _wire_path_provider() -> void:
	_vm.path_provider = func(target: Vector3) -> Array:
		return unit.find_path_to(target)
	_vm.build_provider = func(def_id: String, cell: Vector3i) -> String:
		if build_provider.is_valid():
			return str(build_provider.call(def_id, cell))
		return "没有建筑接口"
	_vm.build_here_provider = func(def_id: String) -> String:
		if build_here_provider.is_valid():
			return str(build_here_provider.call(def_id))
		return "没有建筑接口"
	_vm.place_provider = func(kind: String, cell: Vector3i) -> String:
		if place_provider.is_valid():
			return str(place_provider.call(kind, cell))
		return "没有放置接口"


func _inject_sensors(refresh_lists: bool) -> void:
	var s: Dictionary = unit.sense()
	var radar: Dictionary = unit.radar()
	if refresh_lists or _list_snapshot.is_empty():
		var blocks3: Array = radar.get("blocks3", [])
		_list_snapshot = {
			"blocks": radar["blocks"],
			"heights": radar["heights"],
			"blocks3": blocks3,
			"here": unit.block_here(),
			"enemies": enemies.duplicate(true),
			"orders": orders.duplicate(true),
			"ore": _nearest_ore(blocks3, s["cell"]),
			"below": _first_solid_below(unit, s["pos"]),
		}
	_vm.inject({
		"pos": s["pos"],
		"vel": s["vel"],
		"cell": s["cell"],
		"yaw": s["yaw"],
		"energy": s["energy"],
		"energy_ratio": s["energy_ratio"],
		"hp": unit.hp,
		"hp_max": unit.max_hp,
		"hp_ratio": unit.hp / unit.max_hp if unit.max_hp > 0.0 else 0.0,
		"team": unit.team,
		"thrust": s["thrust"],
		"drill_hits": s["drill_hits"],
		"blocks": _list_snapshot["blocks"],
		"heights": _list_snapshot["heights"],
		"blocks3": _list_snapshot["blocks3"],
		"here": _list_snapshot["here"],
		"enemies": _list_snapshot["enemies"],
		"orders": _list_snapshot["orders"],
		"ore": _list_snapshot.get("ore", {}),
		"below": _list_snapshot.get("below", {}),
		"moving": unit.moving,
		"peace": peace_left,
		"t": _elapsed,
		"res": resources,
		"leader": 1 if is_leader else 0,
	})
