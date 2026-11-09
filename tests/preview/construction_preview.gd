extends SceneTree
## 生成 docs/preview-construction.png：开局几秒，蓝方第一栋楼正在施工

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
		return false
	if _frames == 150:
		var node = null
		for e in _main.buildings:
			if int(e["team"]) == 0:
				node = e["node"]
				break
		if node == null:
			print("没有蓝方建筑")
			quit(1)
			return false
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var center: Vector3 = node.global_position + Vector3(0.0, 2.0, 0.0)
		var eye := center + Vector3(-6.5, 3.4, -6.0)
		rig.position = eye
		var d: Vector3 = center - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.18
	elif _frames == 200:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-construction.png")
		print("SAVED")
		quit(0)
	return false
