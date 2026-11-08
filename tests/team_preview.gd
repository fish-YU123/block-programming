extends SceneTree
## 生成 docs/preview-teams.png：蓝方基地（蓝飞飞 + 建筑）与远处红方飞飞

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
	elif _frames == 900:
		# 把一台红方飞飞拉近到镜头里，方便对比两队配色
		var red: Array = _main.team_units(1)
		if red.size() > 0:
			var ru = red[0]["unit"]
			ru.global_position = Vector3(52.0, ru.global_position.y, 138.0)
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var blue: Array = _main.team_units(0)
		var center := Vector3(34.0, 0.0, 128.0)
		if blue.size() > 0:
			center = blue[0]["unit"].global_position
		var ground: float = float(_main.world.surface_height(int(center.x), int(center.z)))
		var eye := Vector3(center.x - 14.0, ground + 8.5, center.z - 12.0)
		rig.position = eye
		var d: Vector3 = Vector3(center.x + 16.0, ground + 2.0, center.z + 6.0) - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.22
	elif _frames == 960:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-teams.png")
		print("SAVED")
		quit(0)
	return false
