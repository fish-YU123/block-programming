extends SceneTree
## 生成 docs/preview-creative.png：创造模式（无敌人、无分界线）

var _f := 0
var _main: Node

func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main.set_creative_mode(true)
		_main._start_game()
	elif _f == 20:
		var w = _main.world
		var db = _main.db
		var stone: int = db.id_of("stone")
		var y0: int = int(w.surface_height(40, 128))
		for x in range(34, 48):
			for z in range(122, 136):
				w.set_block(Vector3i(x, y0 - 1, z), stone)
				for dy in range(6):
					w.set_block(Vector3i(x, y0 + dy, z), 0)
		_main.place_building_at("powerplant", Vector3i(36, y0, 124), 0)
		_main.place_building_at("charger", Vector3i(36, y0, 130), 0)
		_main.place_building_at("factory", Vector3i(42, y0, 130), 0)
		for e in _main.buildings:
			e["node"].build_left = 0.0
			e["node"]._update_build_progress()
		_main.power_pool[0] = 900.0
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var cam_y: float = maxf(float(y0) + 9.0, float(w.surface_height(31, 118)) + 5.0)
		rig.position = Vector3(31.0, cam_y, 118.0)
		var d: Vector3 = Vector3(40.0, float(y0) + 2.0, 128.0) - rig.position
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.22
	elif _f == 90:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-creative.png")
		print("SAVED")
		quit(0)
	return false
