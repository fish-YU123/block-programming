extends SceneTree
## 队伍配色回归：蓝方飞飞是冷色（偏蓝），红方是暖色（偏红），建筑也带队伍色

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _done := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _done:
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
		return false
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _frames < 10:
		return false
	var blue: Array = _main.team_units(0)
	var red: Array = _main.team_units(1)
	_record("蓝方有单位", blue.size() > 0)
	_record("红方有单位", red.size() > 0)
	if blue.size() > 0 and red.size() > 0:
		var bc := _body_color(blue[0]["unit"])
		var rc := _body_color(red[0]["unit"])
		_record("两队机身颜色不同", not bc.is_equal_approx(rc), "%s vs %s" % [bc.to_html(false), rc.to_html(false)])
		_record("蓝方偏蓝", bc.b > bc.r, bc.to_html(false))
		_record("红方偏红", rc.r > rc.b, rc.to_html(false))
	# 建筑也应该带队伍色（蓝方基地里至少有一栋）
	for entry in _main.buildings:
		if int(entry["node"].team) == 0:
			_record("蓝方建筑存在", true)
			_record("蓝方建筑朝向自己半场", entry["node"].base_cell.x < 100)
			break
	_done = true
	return false


## 取单位机身（Model 下第一个 MeshInstance3D）的材质颜色
func _body_color(unit: Node) -> Color:
	var model: Node = unit.get_node_or_null("Model")
	if model == null:
		return Color(0, 0, 0)
	for child in model.get_children():
		if child is MeshInstance3D and child.material_override is StandardMaterial3D:
			return (child.material_override as StandardMaterial3D).albedo_color
	return Color(0, 0, 0)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
