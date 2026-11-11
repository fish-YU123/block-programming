extends SceneTree
## 生成 docs/preview-skills.png：自爆 / 布雷车 / 维修机 / 干扰机 / 平台机 / 钻地机

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
		var y0: float = float(_main.world.surface_height(40, 128))
		var ids := ["kamikaze", "minelayer", "repair", "jammer", "carrier", "burrower"]
		var i := 0
		for unit_id in ids:
			var def: Dictionary = _main.unit_db.get_def(str(unit_id))
			var at := Vector3(36.0 + float(i) * 2.3, y0 + 3.0, 124.0)
			_main._spawn_unit(def, at, "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%f)\n" % (y0 + 3.0), 0)
			i += 1
	elif _frames == 220:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(40, 128))
		var eye := Vector3(43.0, y0 + 6.5, 133.0)
		rig.position = eye
		var target := Vector3(43.0, y0 + 3.0, 124.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.18
	elif _frames == 250:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-skills.png")
		print("SAVED")
		quit(0)
	return false
