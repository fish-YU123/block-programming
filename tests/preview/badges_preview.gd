extends SceneTree
## 生成 docs/preview-badges.png：没电的飞飞 / 被埋的建筑 / 地基不牢的建筑

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
		var hover := "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(%.1f)\n" % (float(_main.world.surface_height(60, 128)) + 4.0)
		for e in _main.units:
			e["controller"].bind(e["unit"], hover, 42)
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(60, 128))
		for x in range(54, 70):
			for z in range(120, 138):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(8):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		# 建筑一：被方块埋住
		print("buried -> [", _main.place_building_at("miner", Vector3i(58, y0, 124), 0), "]")
		# 建筑二：地基不牢
		print("foundation -> [", _main.place_building_at("factory", Vector3i(64, y0, 128), 0), "]")
		for e in _main.buildings:
			e["node"].build_left = 0.0
			e["node"]._update_build_progress()
		# 给第一栋塞个方块
		w.set_block(Vector3i(58, y0 + 1, 124), stone)
		# 把第二栋的地基挖掉一格
		w.set_block(Vector3i(64, y0 - 1, 128), 0)
		_main._tick_buildings(0.1)
		# 单位：把电量清零显示闪电
		var blue: Array = _main.team_units(0)
		if blue.size() > 0:
			var u = blue[0]["unit"]
			u.global_position = Vector3(55.0, y0 + 4.0, 132.0)
			u.energy_j = u.energy_max * 0.03
			u._physics_process(0.016)
	elif _frames == 60:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(60, 128))
		var eye := Vector3(51.0, y0 + 6.5, 137.0)
		rig.position = eye
		var target := Vector3(61.0, y0 + 2.5, 128.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.2
	elif _frames == 90:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-badges.png")
		print("SAVED")
		quit(0)
	return false
