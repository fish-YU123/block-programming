extends Node
## 单位代码调度器：每物理帧给每个大脑分配指令预算，跑玩家写的程序。
##
## 与旧版（Python 子进程 + 本地 TCP）相比：
## - 不再依赖玩家机器上有 python3；
## - 不再跨进程/网络，因此不会卡物理帧；
## - 玩家代码跑在自研沙箱字节码 VM 里，碰不到文件系统/系统调用（PVP 安全）。

const Deployed = preload("res://scripts/deployed_unit.gd")
const Program = preload("res://scripts/unit_program.gd")

## 每个大脑每秒可执行的语句数（旧实现的 "每秒 60 行"）。
const LINES_PER_SECOND := 60.0
## 单物理帧最多给一个大脑补几步，防止卡顿时集中爆发。
const MAX_STEPS_PER_FRAME := 4

var _programs := {}
var _revisions := {}
var _budgets := {}


func _physics_process(delta: float) -> void:
	var seen := {}
	for node in get_tree().get_nodes_in_group("deployed_unit"):
		var unit := node as Deployed
		if unit == null:
			continue
		if unit.energy_j <= 0.0:
			continue
		var count := unit.center_count()
		if count <= 0:
			continue
		var reading: Dictionary = unit.sense(delta)
		var links: Array = unit.link_payload()
		for index in count:
			var brain := "%s:%s" % [str(unit.uid), str(index)]
			seen[brain] = true
			var program: Program = _programs.get(brain)
			if program == null or int(_revisions.get(brain, -1)) != unit.revision:
				program = Program.new()
				var load_error := program.load_source(unit.source)
				_programs[brain] = program
				_revisions[brain] = unit.revision
				_budgets[brain] = 0.0
				if load_error != "":
					unit.runtime_error = load_error
					continue
			if program.halted():
				unit.runtime_error = program.last_error()
				unit.reapply(delta)
				continue
			program.set_links(links)
			var budget := float(_budgets.get(brain, 0.0)) + delta * LINES_PER_SECOND
			var steps := mini(int(budget), MAX_STEPS_PER_FRAME)
			_budgets[brain] = budget - float(steps)
			if steps <= 0:
				unit.reapply(delta)
				continue
			var drive := 0.0
			var drive_count := 0
			var spin_sum := {}
			var spin_count := {}
			var steer_sum := {}
			var steer_count := {}
			var thrust_sum := {}
			var thrust_count := {}
			var printed := ""
			var failure := ""
			for _step in steps:
				var result: Dictionary = program.step(reading)
				drive += float(result.get("drive", 0.0))
				drive_count += 1
				_accumulate(spin_sum, spin_count, result.get("spin", {}))
				_accumulate(steer_sum, steer_count, result.get("steer", {}))
				_accumulate(thrust_sum, thrust_count, result.get("thrust", {}))
				for line in result.get("logs", []):
					printed += str(line) + "\n"
				var message := str(result.get("error", ""))
				if message != "":
					failure = message
					break
			unit.runtime_error = failure
			if printed != "":
				unit.runtime_log = printed.strip_edges()
			if drive_count > 0:
				unit.spend(
					delta,
					drive / float(drive_count),
					_average(spin_sum, spin_count),
					_average(steer_sum, steer_count),
					_average(thrust_sum, thrust_count),
				)
			else:
				unit.reapply(delta)
	_drop_missing(seen)


func _accumulate(sums: Dictionary, counts: Dictionary, raw) -> void:
	if not (raw is Dictionary):
		return
	for slot in (raw as Dictionary).keys():
		sums[slot] = float(sums.get(slot, 0.0)) + float(raw[slot])
		counts[slot] = int(counts.get(slot, 0)) + 1


func _average(sums: Dictionary, counts: Dictionary) -> Dictionary:
	var out := {}
	for slot in counts.keys():
		out[slot] = float(sums[slot]) / float(counts[slot])
	return out


func _drop_missing(seen: Dictionary) -> void:
	var stale: Array = []
	for key in _programs.keys():
		if not seen.has(str(key)):
			stale.append(key)
	for key in stale:
		_programs.erase(key)
		_revisions.erase(key)
		_budgets.erase(key)


## 给界面用：某单位当前所有大脑的输出（调试面板可显示）。
func brain_count() -> int:
	return _programs.size()
