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

var _vm: PyVM
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
	_vm.load_source(source)
	if _vm.finished and _vm.error != "":
		_halted = true
		_last_error = _vm.error
	_apply_idle_controls()


## 由主场景每帧更新：视野内敌方单位（[{"x","y","z","team"}]，按距离排序）
func set_enemies(list: Array) -> void:
	enemies = list


func halted() -> bool:
	return _halted


func last_error() -> String:
	return _last_error


func tick(delta: float) -> void:
	if unit == null or _vm == null:
		return
	if _halted:
		_apply_idle_controls()
		unit.runtime_error = _last_error
		return
	_inject_sensors()
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
	}
	unit.runtime_error = ""
	unit.runtime_logs = logs


## 跑完一段后决定下一段跑什么：先 start（只跑一次），之后反复跑 loop；
## 两个函数都没写就回到老行为：整段代码从头再跑一遍（mem 保留）。
func _advance() -> void:
	if _vm.error != "":
		return
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
	unit.controls = {"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false}
	unit.runtime_logs = logs


func _inject_sensors() -> void:
	var s: Dictionary = unit.sense()
	var radar: Dictionary = unit.radar()
	_vm.inject({
		"pos": s["pos"],
		"vel": s["vel"],
		"cell": s["cell"],
		"yaw": s["yaw"],
		"energy": s["energy"],
		"energy_ratio": s["energy_ratio"],
		"thrust": s["thrust"],
		"drill_hits": s["drill_hits"],
		"blocks": radar["blocks"],
		"heights": radar["heights"],
		"here": unit.block_here(),
		"enemies": enemies,
	})
