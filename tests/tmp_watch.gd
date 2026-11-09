extends SceneTree
## 观察前 80 秒：建筑数量、下一栋何时放下
var _f := 0
var _main: Node

func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _f % 300 == 0:
		var sec: float = float(_f) / 60.0
		var b: int = _main.buildings.size()
		var done := 0
		var going := 0
		for e in _main.buildings:
			if e["node"].is_under_construction():
				going += 1
			else:
				done += 1
		print("t=%.0fs 建筑=%d（完工 %d / 在建 %d）蓝单位=%d 红建筑=%d" % [sec, b, done, going, _main.team_units(0).size(), _red_buildings()])
	if _f > 60 * 90:
		quit(0)
	return false

func _red_buildings() -> int:
	var n := 0
	for e in _main.buildings:
		if int(e["team"]) == 1:
			n += 1
	return n
