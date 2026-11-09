extends SceneTree
## 生成 docs/preview-building.png：三栋采矿机处在不同施工进度（剖面从下往上）

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	elif _frames == 6:
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(60, 128))
		for x in range(56, 68):
			for z in range(118, 140):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(8):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		var spot_z := [124, 128, 132]
		var left := [9.4, 5.2, 1.2]
		for i in range(3):
			var base := Vector3i(58, y0, int(spot_z[i]))
			print("miner@", base, " -> [", _main.place_building_at("miner", base, 0), "]")
			if _main.buildings.size() > 0:
				var node = _main.buildings[_main.buildings.size() - 1]["node"]
				node.build_left = float(left[i])
				node._update_build_progress()
	elif _frames == 40:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(60, 128))
		var eye := Vector3(50.0, y0 + 5.6, 121.0)
		rig.position = eye
		var target := Vector3(61.0, y0 + 2.2, 129.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.2
	elif _frames == 70:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-building.png")
		print("SAVED")
		quit(0)
	return false
