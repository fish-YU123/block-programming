extends SceneTree
## 生成 docs/preview-defense.png：指挥中心 / 护盾 / 干扰塔 / 炮艇

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
		_main.skip_peace()
	elif _frames == 3:
		for team_econ in [_main.economy, _main.economy_red]:
			team_econ.add("copper", 900)
			team_econ.add("iron", 400)
			team_econ.add("steel", 400)
			team_econ.add("coal", 600)
	elif _frames == 6:
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(40, 128))
		for x in range(32, 54):
			for z in range(118, 140):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(8):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		var spots := [
			["commandpost", Vector3i(36, y0, 122)],
			["shield", Vector3i(46, y0, 122)],
			["jammertower", Vector3i(36, y0, 132)],
			["turret", Vector3i(46, y0, 132)],
		]
		for item in spots:
			var err: String = _main.place_building_at(str(item[0]), item[1], 0)
			print(item[0], " -> [", err, "]")
		for entry in _main.buildings:
			entry["node"].build_left = 0.0
			entry["node"]._update_build_progress()
		_main.power_pool[0] = 900.0
		_main._tick_buildings(1.0)
	elif _frames == 200:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(40, 128))
		var eye := Vector3(30.0, y0 + 10.0, 113.0)
		rig.position = eye
		var target := Vector3(41.0, y0 + 2.0, 128.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.3
	elif _frames == 240:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-defense.png")
		print("SAVED")
		quit(0)
	return false
