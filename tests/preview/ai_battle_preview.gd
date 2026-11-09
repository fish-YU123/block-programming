extends SceneTree
## 生成 docs/preview-ai-battle.png：两台飞飞缠斗的画面

var _frames := 0
var _main: Node
var _shot := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	elif _frames == 60:
		_main.skip_peace()
	elif _frames > 60 and not _shot:
		var blue: Array = _main.team_units(0)
		var red: Array = _main.team_units(1)
		if blue.size() > 0 and red.size() > 0:
			var bu = blue[0]["unit"]
			var ru = red[0]["unit"]
			var mid: Vector3 = (bu.global_position + ru.global_position) * 0.5
			var rig = _main.get_node("CameraRig")
			rig.input_enabled = false
			var eye: Vector3 = mid + Vector3(-4.5, 2.2, 4.5)
			rig.position = eye
			var d: Vector3 = mid - eye
			rig.yaw = atan2(-d.x, -d.z)
			rig.pitch = -0.14
			var dist: float = bu.global_position.distance_to(ru.global_position)
			if dist < 6.0 and _frames > 300:
				root.get_viewport().get_texture().get_image().save_png("res://docs/preview-ai-battle.png")
				print("SAVED at ", _frames, " 距离=", dist)
				_shot = true
				quit(0)
	elif _frames > 3000:
		print("没打起来")
		quit(1)
	return false
