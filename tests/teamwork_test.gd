extends SceneTree
## 协同原语：队伍共享黑板 team_set/team_get、标点 mark/marks、友军 allies

var _main: Node
var _frames := 0
var _passed := 0
var _failed := 0
var _done := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2 or _done:
		return false
	_done = true
	_main.world.build_all()
	_main._start_game()
	_main.skip_peace()
	for e in _main.units:
		e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 99)
	_run()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _passed == _failed else 0 if _failed == 0 else 1)
	return false


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, ("： " + detail) if detail != "" else "")


func _blue() -> Dictionary:
	var list: Array = _main.team_units(_main.TEAM_BLUE)
	return list[0] if list.size() > 0 else {}


func _run() -> void:
	# 1) 队伍共享黑板：provider 直连
	var entry: Dictionary = _blue()
	var controller: RefCounted = entry["controller"]
	controller.team_set_provider.call("测试键", 7.0)
	_record("team_set/team_get 能存能取", float(controller.team_get_provider.call("测试键", 0.0)) == 7.0,
		str(controller.team_get_provider.call("测试键", 0.0)))
	_record("没写过的键返回默认值", float(controller.team_get_provider.call("不存在", 42.0)) == 42.0)

	# 2) 队友之间共享同一块黑板（另一台单位也能读到）
	_main._spawn_unit(_main.unit_db.get_def("feifei"), Vector3(38.0, 0.0, 130.0), "def loop():\n    set_velocity(0.0, 0.0)\n", _main.TEAM_BLUE)
	var second: Dictionary = _main.units[_main.units.size() - 1]
	second["controller"].team_set_provider.call("第二台写的", 9.0)
	_record("全队共用一块黑板", float(controller.team_get_provider.call("第二台写的", 0.0)) == 9.0)

	# 3) 标点：mark_provider 写进队伍标点，同队都能读到
	controller.mark_provider.call(40.0, 30.0, 128.0, "敌人")
	var marks: Array = _main.team_marks[_main.TEAM_BLUE]
	_record("mark 写进队伍标点", marks.size() == 1 and str(marks[0]["tag"]) == "敌人", str(marks.size()))
	_record("标点记录坐标", absf(float(marks[0]["x"]) - 40.0) < 0.01)
	# 同一位置重复标同一点不应该堆一串
	controller.mark_provider.call(40.0, 30.0, 128.0, "敌人")
	_record("同位置重复标点合并", _main.team_marks[_main.TEAM_BLUE].size() == 1, str(_main.team_marks[_main.TEAM_BLUE].size()))

	# 4) 红方的标点是独立的
	controller.mark_provider.call(-1.0, -1.0, -1.0, "错队")
	_record("标点按队伍隔离", _main.team_marks.get(_main.TEAM_RED, []).size() == 0)

	# 5) 传感器注入：allies 里能看到队友
	_main._refresh_enemy_sensors()
	controller.allies = _main._allies_for(entry["unit"], _main.TEAM_BLUE)
	_record("allies 包含队友", controller.allies.size() == 1 and str(controller.allies[0]["type"]) == "feifei",
		str(controller.allies.size()))

	# 6) 玩家代码里能用 team_set / mark（真跑 VM 一段）
	var code := """def loop():
    team_set("代码里写的", 3)
    mark(pos.x + 1.0, pos.y, pos.z, "自己旁边")
    set_velocity(0.0, 0.0)
"""
	controller.bind(entry["unit"], code, 77)
	for i in range(80):
		controller.tick(1.0 / 60.0)
	_record("代码里的 team_set 生效", float(_main.team_boards[_main.TEAM_BLUE].get("代码里写的", 0.0)) == 3.0,
		str(_main.team_boards[_main.TEAM_BLUE].get("代码里写的", 0.0)))
	_record("代码里的 mark 生效", _main.team_marks[_main.TEAM_BLUE].size() >= 2,
		str(_main.team_marks[_main.TEAM_BLUE].size()))
	_record("代码没报错", not controller.halted(), controller.last_error())

	# 7) 代码里能读到 marks / allies / team_mem
	var reader := """def loop():
    if len(marks) > 0:
        team_set("看到标记", 1)
    team_set("队友数量", len(allies))
    team_set("黑板读数", team_get("代码里写的", 0))
    set_velocity(0.0, 0.0)
"""
	# 主循环每帧会把队伍黑板/标点挂到 controller 上，这里手动模拟一次
	controller.board = _main._board_for(_main.TEAM_BLUE)
	controller.marks = _main._marks_for(_main.TEAM_BLUE)
	controller.allies = _main._allies_for(entry["unit"], _main.TEAM_BLUE)
	controller.bind(entry["unit"], reader, 78)
	for i in range(80):
		controller.tick(1.0 / 60.0)
	_record("代码能读到 marks", float(_main.team_boards[_main.TEAM_BLUE].get("看到标记", 0.0)) == 1.0,
		"board=%s err=%s halted=%s" % [str(_main.team_boards[_main.TEAM_BLUE]), controller.last_error(), str(controller.halted())])
	_record("代码能读到 allies", float(_main.team_boards[_main.TEAM_BLUE].get("队友数量", -1.0)) == 1.0,
		str(_main.team_boards[_main.TEAM_BLUE].get("队友数量", -1.0)))
	_record("代码能读回自己写进黑板的值", float(_main.team_boards[_main.TEAM_BLUE].get("黑板读数", 0.0)) == 3.0)

	# 8) 标点 30 秒过期
	_main._prune_marks(31.0)
	_record("标点会过期", _main.team_marks[_main.TEAM_BLUE].size() == 0,
		str(_main.team_marks[_main.TEAM_BLUE].size()))
