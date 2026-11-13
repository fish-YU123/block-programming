extends SceneTree
## 生成 docs/preview-water.png：找一个有水的湖/海拍一张

var _f := 0
var _main: Node
var _spot := Vector3.ZERO


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
	elif _f == 6:
		var w = _main.world
		var best := Vector3.ZERO
		var best_score := -1
		for x in range(20, 236, 6):
			for z in range(18, 238, 6):
				var h: int = w.surface_height(x, z)
				if h <= 21:
					# 水面越开阔越好：看周围 8 格有多少也是水
					var score := 0
					for dx in range(-4, 5, 2):
						for dz in range(-4, 5, 2):
							if w.surface_height(x + dx, z + dz) <= 21:
								score += 1
					if score > best_score:
						best_score = score
						best = Vector3(float(x), float(h), float(z))
		_spot = best
		print("水面采样点 ", best, " 开阔度 ", best_score)
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		rig.position = Vector3(best.x, 46.0, best.z + 26.0)
		var look := Vector3(best.x + 2.0, 16.0, best.z - 6.0)
		var d: Vector3 = look - rig.position
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.55
	elif _f == 120:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-water.png")
		print("SAVED")
		quit(0)
	return false
