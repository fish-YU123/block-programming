extends SceneTree
## 生成 docs/preview-feel.png：单位不重叠 + 命中火花 + 白闪

var _f := 0
var _main: Node
var _units: Array = []


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
		_main.skip_peace()
	elif _f == 6:
		var h: int = _main.world.surface_height(40, 120)
		var hover := "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%.1f)\n" % (float(h) + 6.0)
		for e in _main.units:
			e["controller"].bind(e["unit"], hover, 42)
		# 在同一个点上硬塞 6 台，看出生点自动错开
		for i in 5:
			_main._spawn_unit(_main.unit_db.get_def("feifei"), Vector3(40.0, float(h), 120.0), hover, 0)
		_units = _main.team_units(0)
	elif _f == 120:
		# 打它们几下，蹦火花 + 白闪
		for i in range(mini(3, _units.size())):
			_main._queue_damage(_units[i]["unit"], 30.0)
		_main._flush_damage()
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var mid := Vector3.ZERO
		for e in _units:
			mid += e["unit"].global_position
		mid /= float(maxi(1, _units.size()))
		rig.position = mid + Vector3(-5.5, 2.6, 5.0)
		var d: Vector3 = mid - rig.position
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.16
	elif _f == 128:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-feel.png")
		print("SAVED")
		quit(0)
	return false
