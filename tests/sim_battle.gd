extends SceneTree
## 长时间对战模拟（开发用）：打印时间线，观察平衡与卡死
## 用法：--script res://tests/sim_battle.gd -- --world-seed=1 [--skip-peace] [--max=<秒>]

var _main: Node
var _frames := 0
var _next_report := 0
var _max_frames := 7200
var _skip_peace := false
var _started := false
var _last_report := -1


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if str(arg) == "--skip-peace":
			_skip_peace = true
		elif str(arg).begins_with("--max="):
			_max_frames = int(str(arg).substr(6)) * 60
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		if _skip_peace:
			_main.skip_peace()
		return false
	if not _main._world_ready:
		return false
	if _main._physics_frames % 300 == 0 and _main._physics_frames != _last_report:
		_last_report = _main._physics_frames
		_report()
	if _main.game_over != "":
		print("结束于 %.0fs：%s" % [float(_main._physics_frames) / 60.0, _main.game_over])
		_report()
		quit(0)
		return false
	if _main._physics_frames >= _max_frames:
		print("超时 %.0fs 未分胜负（双方都还活着）" % (float(_main._physics_frames) / 60.0))
		_report()
		quit(2)
		return false
	return false


func _report() -> void:
	var blue: int = _main.team_units(0).size()
	var red: int = _main.team_units(1).size()
	var blue_buildings := 0
	var red_buildings := 0
	for entry in _main.buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or node.is_under_construction():
			continue
		if int(node.team) == 0:
			blue_buildings += 1
		else:
			red_buildings += 1
	if true:
		var brief: Array = []
		for entry in _main.units:
			var u: RigidBody3D = entry["unit"]
			if not u.alive:
				continue
			var ctl: Dictionary = u.controls
			brief.append("%s%d(%.0f,%.0f,%.0f hp%.0f e%.0f L%.2f Pi%.2f vm%s gh%s)" % [
				"B" if int(u.team) == 0 else "R", int(entry["uid"]),
				u.global_position.x, u.global_position.y, u.global_position.z, u.hp, u.energy_j / 1000.0,
				float(ctl.get("lift", 0.0)), float(ctl.get("pitch", 0.0)),
				str(ctl.get("vel_mode")), str(u.has_goal)])
			var ctrl2 = entry["controller"]
			brief.append("[fin=%s err=%s budget=%.2f]" % [str(ctrl2._vm.finished), str(ctrl2._vm.error), float(ctrl2._budget)])
			if entry["controller"].halted():
				brief.append("[halted:%s]" % str(entry["controller"].last_error()))
		print("   单位（main.peace=%.2f）：" % _main.peace_left, " ".join(brief))
	var blue_res: Dictionary = _main.economy.all()
	var red_res: Dictionary = _main.economy_red.all()
	print("t=%3.0fs 蓝=%d台/%d栋 红=%d台/%d栋 蓝铜=%d钢=%d 红铜=%d钢=%d 电量=%.0f/%.0f 和平=%.0f" % [
		float(_main._physics_frames) / 60.0, blue, blue_buildings, red, red_buildings,
		int(blue_res.get("copper", 0)), int(blue_res.get("steel", 0)),
		int(red_res.get("copper", 0)), int(red_res.get("steel", 0)),
		_main.power_of(0), _main.power_of(1), _main.peace_left,
	])
