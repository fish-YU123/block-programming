extends SceneTree
## 生成 docs/preview-duel.png：开局蓝红各一台飞飞自动对局

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 6:
		_main.get_node("CameraRig").input_enabled = false
	elif _frames >= 380 and _frames < 470:
		# 相机跟着两台的中间点，保证它们都在画面里
		var rig = _main.get_node("CameraRig")
		var blue: Array = _main.team_units(0)
		var red: Array = _main.team_units(1)
		if blue.size() > 0 and red.size() > 0:
			var mid: Vector3 = (blue[0]["unit"].global_position + red[0]["unit"].global_position) * 0.5
			var eye: Vector3 = mid + Vector3(-10.0, 4.0, 10.0)
			rig.position = eye
			var d: Vector3 = mid - eye
			rig.yaw = atan2(-d.x, -d.z)
			rig.pitch = -0.18
	elif _frames == 470:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-duel.png")
		print("SAVED")
		quit(0)
	return false
