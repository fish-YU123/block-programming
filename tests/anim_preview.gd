extends SceneTree
## 生成 docs/preview-anim.png：动画/建模一览（尾焰、雷达罩、烟囱冒烟、圆环）

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
	elif _frames == 6:
		# 冻结 AI，人工摆一排：飞飞 + 组装厂 + 充电站
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(60, 128))
		for x in range(52, 74):
			for z in range(118, 140):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(9):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		print("factory -> [", _main.place_building_at("factory", Vector3i(58, y0, 126), 0), "]")
		print("charger -> [", _main.place_building_at("charger", Vector3i(64, y0, 131), 0), "]")
		print("miner -> [", _main.place_building_at("miner", Vector3i(64, y0, 122), 0), "]")
		# 把建筑直接建好，省得等
		for e in _main.buildings:
			e["node"].build_left = 0.0
			e["node"]._update_build_progress()
		# 把蓝方飞飞摆到镜头前
		var blue: Array = _main.team_units(0)
		if blue.size() > 0:
			var u = blue[0]["unit"]
			u.global_position = Vector3(56.0, y0 + 4.0, 132.0)
			u.rotation.y = -PI * 0.5
			u.controls["lift"] = 0.85
	elif _frames == 240:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(60, 128))
		var eye := Vector3(52.0, y0 + 6.0, 132.0)
		rig.position = eye
		var target := Vector3(64.0, y0 + 2.5, 127.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.16
	elif _frames == 300:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-anim.png")
		print("SAVED")
		quit(0)
	return false
