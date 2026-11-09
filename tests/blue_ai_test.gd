extends SceneTree
## 蓝方预设 AI 的回归测试：开局造建筑 → 攒出更多单位 → 赢下对局

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _saw_buildings := false
var _saw_units := false
var _saw_red_units := false
var _skipped := false
var _done := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _frames < 6:
		return false
	if _done:
		if _frames > 6:
			print("通过 %d 项，失败 %d 项" % [_passed, _failed])
			quit(0 if _failed == 0 else 1)
		return false
	# 1) 蓝方指挥官在发育期就把建筑盖起来了
	if _main.buildings.size() >= 3:
		_saw_buildings = true
	# 2) 组装厂把两方单位数量都拉起来（两队现在跑同一套 AI）
	if _main.team_units(0).size() >= 2:
		_saw_units = true
	if _main.team_units(1).size() >= 2:
		_saw_red_units = true
	# 3) 攒够部队就跳过发育时间，直接开打
	if not _skipped and _saw_units and _saw_buildings:
		_main.skip_peace()
		_skipped = true
	# 4) 分出胜负
	if _main.game_over != "":
		_record("至少造了 3 栋建筑", _saw_buildings)
		_record("蓝方靠组装厂攒出更多单位", _saw_units)
		_record("红方也靠组装厂攒出更多单位", _saw_red_units)
		_record("对局分出胜负", true, str(_main.game_over))
		_record("全程没有单位代码报错", not _any_error())
		_done = true
		return false
	if _frames > 60 * 240:
		_record("至少造了 3 栋建筑", _saw_buildings)
		_record("蓝方靠组装厂攒出更多单位", _saw_units)
		_record("红方也靠组装厂攒出更多单位", _saw_red_units)
		_record("对局分出胜负", false, "超时")
		_done = true
	return false


func _any_error() -> bool:
	for team in [0, 1]:
		for entry in _main.team_units(team):
			if str(entry["controller"].last_error()) != "":
				return true
	return false


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
