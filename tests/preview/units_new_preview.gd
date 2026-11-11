extends SceneTree
## 生成 docs/preview-new-units.png：建筑工 + 侦察机 + 雷达站 + 维修厂

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
		_main.economy.add("copper", 600)
		_main.economy.add("iron", 200)
		_main.economy.add("coal", 300)
	elif _frames == 6:
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(40, 124))
		for x in range(34, 52):
			for z in range(116, 136):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(5):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		_main.place_building_at("radar", Vector3i(37, y0, 120), 0)
		_main.place_building_at("repairbay", Vector3i(37, y0, 128), 0)
		for entry in _main.buildings:
			entry["node"].build_left = 0.0
			entry["node"]._update_build_progress()
		_main.power_pool[0] = 500.0
		# 摆一台建筑工和一台侦察机
		var bdef: Dictionary = _main.unit_db.get_def("builder")
		_main._spawn_unit(bdef, Vector3(44.0, 0.0, 124.0), _main._preset_for_unit(bdef), 0)
		var sdef: Dictionary = _main.unit_db.get_def("scout")
		_main._spawn_unit(sdef, Vector3(47.0, 0.0, 128.0), _main._preset_for_unit(sdef), 0)
		var hover := "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%.1f)\n" % (float(y0) + 3.0)
		for e in _main.units:
			e["controller"].bind(e["unit"], hover, 7)
			e["unit"].global_position.y = float(y0) + 3.0
	elif _frames == 160:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(40, 124))
		var eye := Vector3(31.0, y0 + 8.0, 110.0)
		rig.position = eye
		var target := Vector3(41.0, y0 + 2.0, 128.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.3
	elif _frames == 200:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-new-units.png")
		print("SAVED")
		quit(0)
	return false
