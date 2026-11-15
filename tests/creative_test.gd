extends SceneTree
## 创造模式：没有敌人、没有分界线

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, ("（%s）" % detail) if detail else "")
	else:
		_failed += 1
		print("  ✗ ", name, ("（%s）" % detail) if detail else "")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames != 2:
		return false
	_main.world.build_all()
	_main.set_creative_mode(true)
	_main._start_game()
	return _run()


func _run() -> bool:
	_record("创造模式已开启", _main.creative_mode)
	_record("开局没有红方单位", _main.team_units(1).is_empty(), "红方 %d 台" % _main.team_units(1).size())
	_record("开局没有蓝方单位", _main.team_units(0).is_empty(), "蓝方 %d 台" % _main.team_units(0).size())
	var lines_visible := false
	for node in _main.world._line_nodes:
		if node != null and node.visible:
			lines_visible = true
	_record("分界线已隐藏", not lines_visible)
	_record("资源充足", _main.economy.amount("copper") > 100000 and _main.economy_red.amount("copper") > 100000,
		"蓝 %d / 红 %d" % [_main.economy.amount("copper"), _main.economy_red.amount("copper")])
	# 跑 90 帧不应该判胜负
	for i in 90:
		_main._physics_process(1.0 / 60.0)
	_record("不会误判胜负", _main.game_over == "", _main.game_over)
	# 能正常放单位
	var def: Dictionary = _main.unit_db.get_def("feifei")
	_main._spawn_unit(def, Vector3(34.0, 0.0, 128.0), "def loop():\n    set_lift(0.6)\n", 0)
	_record("创造模式能放单位", _main.team_units(0).size() == 1, "%d 台" % _main.team_units(0).size())
	# 关掉后分界线回来
	_main.set_creative_mode(false)
	var lines_back := true
	for node in _main.world._line_nodes:
		if node != null and node.is_inside_tree() and not node.visible:
			lines_back = false
	_record("关闭后分界线恢复", lines_back)
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
	return true
