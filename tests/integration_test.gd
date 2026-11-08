extends SceneTree
## 集成测试：Deployed + UnitVM 驱动链路（无需场景，手动推进物理帧）
##   godot --headless --path . --script res://tests/integration_test.gd

const Deployed = preload("res://scripts/deployed_unit.gd")
const UnitVM = preload("res://scripts/unit_vm.gd")

var _uid_next := 1
var _passed := 0
var _failed := 0
var _failures: Array = []


var _started := false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_test_drive_loop()
	_test_print_log()
	_test_runtime_error()
	_test_multiple_brains()
	_test_revision_reload()
	_test_energy_zero()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + str(item))
	quit(0 if _failed == 0 else 1)
	return false


func _make_unit(source: String, brains: int, wheels: int = 1) -> Deployed:
	var unit := Deployed.new()
	unit.uid = _uid_next
	_uid_next += 1
	unit.source = source
	unit.energy_j = 500.0
	unit.energy_max = 500.0
	for i in wheels:
		unit.link_names.append("wheel%d" % (i + 1))
		unit.link_kinds.append("wheel")
		unit.link_slots.append(i)
	for i in brains:
		var center := RigidBody3D.new()
		unit.add_child(center)
		unit.centers.append(center)
	return unit


func _test_drive_loop() -> void:
	var unit := _make_unit("set_drive(1)\n", 1)
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 120:
		vm._physics_process(1.0 / 60.0)
	_record("驱动 set_drive", is_equal_approx(unit._last_drive, 1.0), "最后 drive=%s" % str(unit._last_drive))
	_record("驱动 无错误", unit.runtime_error == "", unit.runtime_error)
	_teardown(unit, vm)


func _test_print_log() -> void:
	var unit := _make_unit("print(\"x\", 1 + 1)\n", 1)
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 30:
		vm._physics_process(1.0 / 60.0)
	_record("print 日志", unit.runtime_log == "x 2", "日志=%s" % unit.runtime_log)
	_teardown(unit, vm)


func _test_runtime_error() -> void:
	var unit := _make_unit("x = 1 + \"a\"\n", 1)
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 10:
		vm._physics_process(1.0 / 60.0)
	_record("运行错误上报", unit.runtime_error.find("第 1 行") >= 0, unit.runtime_error)
	_teardown(unit, vm)


func _test_multiple_brains() -> void:
	var unit := _make_unit("if \"k\" in mem:\n    mem[\"k\"] += 1\nelse:\n    mem[\"k\"] = 1\nprint(mem[\"k\"])\n", 2)
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 40:
		vm._physics_process(1.0 / 60.0)
	_record("多大脑独立运行", unit.runtime_error == "", unit.runtime_error)
	_record("多大脑有输出", unit.runtime_log != "", unit.runtime_log)
	_teardown(unit, vm)


func _test_revision_reload() -> void:
	var unit := _make_unit("set_drive(0.25)\n", 1)
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 20:
		vm._physics_process(1.0 / 60.0)
	_record("改版前 drive", is_equal_approx(unit._last_drive, 0.25), str(unit._last_drive))
	unit.source = "set_drive(0.75)\n"
	unit.revision += 1
	for i in 20:
		vm._physics_process(1.0 / 60.0)
	_record("改版后 drive", is_equal_approx(unit._last_drive, 0.75), str(unit._last_drive))
	_teardown(unit, vm)


func _test_energy_zero() -> void:
	var unit := _make_unit("set_drive(1)\n", 1)
	unit.energy_j = 0.0
	var vm := UnitVM.new()
	get_root().add_child(unit)
	get_root().add_child(vm)
	unit.add_to_group("deployed_unit")
	for i in 20:
		vm._physics_process(1.0 / 60.0)
	_record("断电不执行", is_equal_approx(unit._last_drive, 0.0), str(unit._last_drive))
	_teardown(unit, vm)


func _teardown(unit: Deployed, vm: UnitVM) -> void:
	unit.remove_from_group("deployed_unit")
	unit.get_parent().remove_child(unit)
	unit.free()
	vm.get_parent().remove_child(vm)
	vm.free()


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
