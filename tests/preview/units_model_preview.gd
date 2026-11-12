extends SceneTree
## 生成 docs/preview-unit-models.png：12 种单位站一排看造型

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
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		for team_econ in [_main.economy, _main.economy_red]:
			team_econ.add("copper", 900)
			team_econ.add("iron", 400)
			team_econ.add("steel", 400)
			team_econ.add("coal", 600)
	elif _frames == 6:
		var ids := ["feifei", "rover", "builder", "scout", "cargo", "gunship",
			"kamikaze", "minelayer", "repair", "jammer", "burrower", "carrier"]
		var y0: float = float(_main.world.surface_height(40, 128))
		var i := 0
		for uid in ids:
			var def: Dictionary = _main.unit_db.get_def(str(uid))
			var is_ground := bool(def.get("ground", false)) or str(uid) == "rover"
			var h := y0 + 1.6 if is_ground else y0 + 4.0
			var col := i % 6
			var row := i / 6
			var at := Vector3(34.0 + float(col) * 2.2, h, 123.0 + float(row) * 5.0)
			var hold := "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%.1f)\n" % h
			_main._spawn_unit(def, at, hold, 0)
			i += 1
	elif _frames == 160:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(40, 128))
		var eye := Vector3(40.0, y0 + 8.0, 137.0)
		rig.position = eye
		var target := Vector3(40.0, y0 + 2.8, 126.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.28
	elif _frames == 200:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-unit-models.png")
		print("SAVED")
		quit(0)
	return false
