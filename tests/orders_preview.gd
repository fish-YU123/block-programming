extends SceneTree
## 生成 docs/preview-orders.png：虚影标记 + 飞飞

var _frames := 0
var _main: Node
var _unit: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 4:
		var entry: Dictionary = _main.team_units(0)[0]
		_unit = entry["unit"]
		# 让飞飞只悬停，免得它把标记干活干掉了
		entry["controller"].bind(_unit, "def loop():\n    set_lift(0.6)\n", 99)
		rig.input_enabled = false
		var h: int = _main.world.surface_height(40, 128)
		_unit.global_position = Vector3(40.0, float(h) + 7.0, 128.0)
		# 三种虚影
		for dz in range(-1, 2):
			var cell := Vector3i(43, _main.world.surface_height(43, 128 + dz), 128 + dz)
			_main.toggle_order(cell, _main.ORDER_MINE)
		var place_cell := Vector3i(44, _main.world.surface_height(44, 130) + 1, 130)
		_main.toggle_order(place_cell, _main.ORDER_PLACE, "planks")
		var base := Vector3i(46, _main.world.surface_height(46, 126) + 1, 126)
		_main.toggle_order(base, _main.ORDER_BUILD, "factory")
		_main._refresh_hud()
		var eye: Vector3 = Vector3(36.0, float(h) + 12.0, 138.0)
		rig.position = eye
		var look: Vector3 = Vector3(44.0, float(h) + 2.0, 128.0)
		var d: Vector3 = look - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.4
	elif _frames == 150:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-orders.png")
		print("SAVED")
		quit(0)
	return false
