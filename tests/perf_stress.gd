extends SceneTree
## 后期压力性能探针：塞满单位与建筑，测帧时间与各系统耗时

var _frames := 0
var _main: Node
var _accum := 0.0
var _worst := 0.0
var _worst_at := 0
var _t0 := 0
var _physics_accum := 0.0
var _last_phys_us := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_usec()
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	if _frames == 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_frames += 1
	if _frames == 2:
		print("启动耗时: %.0f ms" % ((Time.get_ticks_usec() - _t0) / 1000.0))
		_main.profile_enabled = true
		load("res://scripts/units/unit_controller.gd").profile_enabled = true
		_main.world.build_all()
		_main._start_game()
		_main.skip_peace()
		# 塞 24 台单位（每队 12 台，各种类型）+ 每队 8 栋建筑
		var ids := ["feifei", "gunship", "scout", "cargo", "repair", "jammer", "kamikaze", "carrier", "minelayer", "burrower", "builder", "rover"]
		for team in [0, 1]:
			for i in 12:
				var def: Dictionary = _main.unit_db.get_def(ids[i % ids.size()])
				var x: float = (40.0 if team == 0 else 200.0) + float(i % 4) * 3.0
				var z: float = 100.0 + float(i) * 2.5
				_main._spawn_unit(def, Vector3(x, float(_main.world.surface_height(int(x), int(z))), z), _main._preset_for_unit(def), team)
			var kinds := ["miner", "factory", "charger", "powerplant", "battery", "turret", "radar", "repairbay"]
			for i in 8:
				var spot := _flat_spot(Vector2i(60 if team == 0 else 190, 100 + i * 6))
				if spot != Vector3i(-1, -1, -1):
					_main.place_building_at(kinds[i % kinds.size()], spot, team)
		for entry in _main.buildings:
			entry["node"].build_left = 0.0
			entry["node"]._update_build_progress()
		for team in [0, 1]:
			_main.power_pool[team] = 900.0
		return false
	if _frames > 40:
		_accum += delta
		var ms := delta * 1000.0
		if ms > _worst:
			_worst = ms
			_worst_at = _frames
		if _frames % 60 == 0:
			print("t=%d 帧 单位=%d 建筑=%d 火花=%d" % [_frames, _main.units.size(), _main.buildings.size(), _main.fx_count()])
		if _frames == 400:
			var avg := _accum / float(_frames - 40) * 1000.0
			print("== 平均帧时间 %.2f ms（%.0f fps）" % [avg, 1000.0 / avg])
			print("== 最慢帧 %.2f ms @ 第 %d 帧" % [_worst, _worst_at])
			var ctrl = load("res://scripts/units/unit_controller.gd")
			print("    controller: inject %.1f ms / step %.1f ms / 其余 %.1f ms" % [
				float(ctrl.prof_inject_us) / 1000.0, float(ctrl.prof_step_us) / 1000.0, float(ctrl.prof_rest_us) / 1000.0])
			for k in _main.profile_us.keys():
				print("    %-12s %7.1f ms" % [str(k), float(_main.profile_us[k]) / 1000.0])
			print("== draw calls %d / primitives %d / objects %d" % [
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
			quit(0)
	return false


func _flat_spot(near: Vector2i) -> Vector3i:
	var world = _main.world
	var db = _main.db
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near.x + dx
			var z: int = near.y + dz
			if x < 4 or z < 4 or x > 250 or z > 250:
				continue
			var h: int = world.surface_height(x, z)
			var ok := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						ok = false
					if world.get_block(Vector3i(x + ox, h, z + oz)) != db.id_of("air"):
						ok = false
			if ok:
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)
