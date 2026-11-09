extends SceneTree
## 生成 docs/preview-units-team.png：蓝方与红方的飞飞并排特写

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
	elif _frames == 30:
		var blue: Array = _main.team_units(0)
		var red: Array = _main.team_units(1)
		if blue.size() > 0:
			var bu = blue[0]["unit"]
			bu.global_position = Vector3(36.0, bu.global_position.y, 126.0)
			bu.rotation.y = -PI * 0.5
		if red.size() > 0:
			var ru = red[0]["unit"]
			ru.global_position = Vector3(40.0, ru.global_position.y, 130.0)
			ru.rotation.y = PI * 0.5
	elif _frames == 200:
		# 冻结两台单位（不然它们会自己飞走），摆到镜头前
		var blue2: Array = _main.team_units(0)
		var red2: Array = _main.team_units(1)
		# 清掉建筑，免得挡镜头（这张图只看单位配色）
		for bentry in _main.buildings:
			bentry["node"].queue_free()
		_main.buildings.clear()
		var gy: float = float(_main.world.surface_height(38, 121)) + 3.0
		var hover := "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%.1f)\n" % gy
		if blue2.size() > 0:
			var b2 = blue2[0]
			b2["controller"].bind(b2["unit"], hover, 99)
			b2["unit"].global_position = Vector3(36.0, gy, 120.0)
			b2["unit"].rotation.y = -PI * 0.5
		if red2.size() > 0:
			var r2 = red2[0]
			r2["controller"].bind(r2["unit"], hover, 99)
			r2["unit"].global_position = Vector3(40.5, gy, 122.5)
			r2["unit"].rotation.y = PI * 0.5
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var ground: float = float(_main.world.surface_height(38, 121)) + 3.0
		var eye := Vector3(31.5, ground + 1.6, 114.5)
		rig.position = eye
		var target := Vector3(38.2, ground - 0.2, 121.2)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.18
	elif _frames == 300:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-units-team.png")
		print("SAVED")
		quit(0)
	return false
