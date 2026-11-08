extends SceneTree
## 预设单位（飞飞）回归测试：headless 运行
##   godot --headless --path . --script res://tests/flyer_test.gd

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
const UnitController = preload("res://scripts/units/unit_controller.gd")
const DefaultCode = preload("res://scripts/units/unit_code_default.gd")

var _passed := 0
var _failed := 0
var _failures: Array = []

var _world: VoxelWorld
var _db: BlockDB
var _unit: Flyer
var _controller: UnitController
var _drill_unit: Flyer
var _frames := 0
var _ground_y := 0
var _target_y := 0.0
var _energy_start := 0.0


func _initialize() -> void:
	_db = BlockDB.new()
	var problem := _db.load_dir("res://data/blocks")
	_record("方块表加载", problem == "", problem)

	var units := UnitDB.new()
	var uproblem := units.load_dir("res://data/units")
	_record("预设单位表加载", uproblem == "", uproblem)
	var def: Dictionary = units.get_def("feifei")
	_record("飞飞存在", not def.is_empty(), "找不到 feifei")
	_record("飞飞显示名", str(def.get("display_name", "")) == "飞飞", str(def.get("display_name", "")))
	_record("飞飞质量 12kg", float(def.get("mass", 0.0)) == 12.0, str(def.get("mass", 0)))
	_record("飞飞尺寸 0.75", float(def.get("size", 0.0)) == 0.75, str(def.get("size", 0)))
	_record("飞飞雷达半径 2（5×5）", int(def.get("radar_radius", 0)) == 2, str(def.get("radar_radius", 0)))

	_world = VoxelWorld.new()
	root.add_child(_world)
	_world.setup(_db, 4242, 64, 64, 48)
	_world.build_all()

	_ground_y = _world.surface_height(20, 20)
	_unit = _spawn(Vector3(20.0, float(_ground_y) + 6.0, 20.0))
	_controller = UnitController.new()
	_controller.bind(_unit, DefaultCode.FLYER_SOURCE, 1)
	_target_y = float(_ground_y) + 6.0
	_energy_start = _unit.energy_j
	var drill_h := _world.surface_height(40, 20)
	for dx in range(-1, 2):
		for dy in range(0, 4):
			_world.set_block(Vector3i(40 + dx, drill_h + 1 + dy, 19), _db.id_of("stone"))
	_drill_unit = _spawn(Vector3(40.0, float(drill_h) + 2.0, 21.0))


func _spawn(at: Vector3) -> Flyer:
	var unit := Flyer.new()
	root.add_child(unit)
	unit.global_position = at
	var defs := UnitDB.new()
	defs.load_dir("res://data/units")
	unit.setup(_world, defs.get_def("feifei"))
	return unit


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_controller.tick(0.016)  # 让 VM 至少跑一次
	if _frames > 2:
		_controller.tick(0.016)
		_drill_unit.controls["drill"] = true
	if _frames == 240:
		_finish()
	return false


func _finish() -> void:
	# 1) 悬停
	var altitude := _unit.global_position.y - float(_ground_y)
	_record("悬停高度保持在目标 ±2 米", absf(_unit.global_position.y - _target_y) < 2.0, "当前 %.2f 目标 %.2f" % [_unit.global_position.y, _target_y])
	_record("没有掉到地上", altitude > 2.0, "%.2f" % altitude)
	_record("代码没有报错", not _controller.halted(), _controller.last_error())
	_record("电量在消耗", _unit.energy_j < _energy_start, "%.0f" % _unit.energy_j)

	# 2) 雷达
	var radar: Dictionary = _unit.radar()
	_record("雷达行数 5", radar["blocks"].size() == 5, str(radar["blocks"].size()))
	_record("雷达列数 5", radar["blocks"][0].size() == 5, str(radar["blocks"][0].size()))
	var cx := floori(_unit.global_position.x)
	var cz := floori(_unit.global_position.z)
	_record("雷达中心高度是地表", int(radar["heights"][2][2]) == _world.surface_y(cx, cz), "%s vs %s" % [str(radar["heights"][2][2]), str(_world.surface_y(cx, cz))])
	_record("雷达中心方块名有效", str(radar["blocks"][2][2]) != "", str(radar["blocks"][2][2]))

	# 3) 外形尺寸不超过 0.75 米立方
	var box := _visual_aabb(_unit)
	var max_dim: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	_record("外形不超过 0.75 米", max_dim <= 0.76, "外接盒 %.2f × %.2f × %.2f" % [box.size.x, box.size.y, box.size.z])

	# 4) 激光钻头
	_record("钻头挖到方块", _drill_unit.drill_hits > 0, str(_drill_unit.drill_hits))

	# 5) 断电后没有推力
	_unit.energy_j = 0.0
	_unit.controls["lift"] = 1.0
	_unit._physics_process(0.016)
	_record("没电时升力失效", _unit.thrust_now == 0.0, str(_unit.thrust_now))

	# 6) start / loop 两段式代码
	var UnitController = preload("res://scripts/units/unit_controller.gd")
	var ctrl = UnitController.new()
	var flyer2 = load("res://scripts/units/flyer.gd").new()
	root.add_child(flyer2)
	var udb = load("res://scripts/units/unit_db.gd").new()
	udb.load_dir("res://data/units")
	flyer2.setup(_world, udb.get_def("feifei"))
	ctrl.bind(flyer2, "def start():\n    mem[\"n\"] = 0\n    mem[\"started\"] = 1\n\ndef loop():\n    mem[\"n\"] = mem[\"n\"] + 1\n    set_lift(0.5)\n", 1)
	for i in 200:
		flyer2._physics_process(0.016)
		ctrl.tick(0.05)
	var state: Dictionary = ctrl._vm.state
	_record("start 只跑一次", int(state["mem"].get("started", 0)) == 1, str(state["mem"]))
	_record("loop 反复跑", int(state["mem"].get("n", 0)) >= 2, str(state["mem"]))
	_record("loop 里的控制量生效", is_equal_approx(float(flyer2.controls["lift"]), 0.5), str(flyer2.controls))
	flyer2.queue_free()

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + item)
	quit(0 if _failed == 0 else 1)


func _visual_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var stack: Array = [node]
	while not stack.is_empty():
		var current = stack.pop_back()
		if current is MeshInstance3D and current.mesh != null and current.visible:
			var aabb: AABB = current.global_transform * current.mesh.get_aabb()
			if first:
				result = aabb
				first = false
			else:
				result = result.merge(aabb)
		for child in current.get_children():
			stack.append(child)
	return result


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
