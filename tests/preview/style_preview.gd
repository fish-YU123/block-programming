extends SceneTree
## 生成 docs/preview-art-style.png：画风统一对照（双色低噪方块 + 纯色描边建筑，右侧站着单位）

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
		for k in ["copper", "iron", "coal"]:
			_main.economy.add(k, 800)
	elif _frames == 6:
		for e in _main.units:
			e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 42)
		var w = _main.world
		var db = _main.db
		var y0: int = int(w.surface_height(40, 124))
		for x in range(34, 54):
			for z in range(116, 138):
				w.set_block(Vector3i(x, y0 - 1, z), db.id_of("stone"))
				for dy in range(6):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		# 一排方块材质对比：草 / 泥土 / 石 / 沙 / 木 / 矿
		var row := ["grass", "dirt", "stone", "sand", "planks", "coal_ore", "copper_ore", "iron_ore", "gold_ore"]
		for i in row.size():
			w.set_block(Vector3i(34 + i, y0, 118), db.id_of(row[i]))
			w.set_block(Vector3i(34 + i, y0 + 1, 118), db.id_of(row[i]))
		_main.place_building_at("radar", Vector3i(39, y0, 124), 0)
		_main.place_building_at("repairbay", Vector3i(39, y0, 130), 0)
		for entry in _main.buildings:
			entry["node"].build_left = 0.0
			entry["node"]._update_build_progress()
		_main.power_pool[0] = 500.0
		var bdef: Dictionary = _main.unit_db.get_def("builder")
		_main._spawn_unit(bdef, Vector3(45.0, 0.0, 126.0), _main._preset_for_unit(bdef), 0)
		var sdef: Dictionary = _main.unit_db.get_def("scout")
		_main._spawn_unit(sdef, Vector3(45.0, 0.0, 129.0), _main._preset_for_unit(sdef), 0)
	elif _frames == 150:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var y0: float = float(_main.world.surface_height(40, 124))
		var eye := Vector3(36.0, y0 + 3.4, 120.0)
		rig.position = eye
		var target := Vector3(44.0, y0 + 1.3, 129.0)
		var d: Vector3 = target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.20
	elif _frames == 200:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-art-style.png")
		print("SAVED")
		quit(0)
	return false
