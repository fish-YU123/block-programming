extends SceneTree
## 代码面板测试：headless 运行
##   godot --headless --path . --script res://tests/editor_test.gd

var _passed := 0
var _failed := 0
var _failures: Array = []
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		_check()
	return false


func _check() -> void:
	var panel = _main.code_panel
	_record("开局面板是关闭的", not panel.is_open(), "面板开着")
	_main._toggle_code_panel()
	_record("按 C 打开面板", panel.is_open(), "没打开")
	_main._sync_input_state()
	_record("在代码框里打字时相机不动", _main.rig.input_enabled == false, "相机仍可操作")

	# 点别处 → 代码框失去焦点 → WASD 恢复
	panel.editor.release_focus()
	_main._sync_input_state()
	_record("点别处后恢复移动", _main.rig.input_enabled == true, "相机被锁住")

	# 滚轮调视野
	var fov_before: float = _main.rig.camera.fov
	_main.rig.zoom(-1.0)
	_record("滚轮缩小视野", _main.rig.camera.fov < fov_before, "%s -> %s" % [fov_before, _main.rig.camera.fov])
	_main.rig.zoom(1.0)

	# 重新运行：版本号 +1，程序重新加载
	var uid0: int = int(_main.units[0]["uid"])
	var rev0: int = int(_main.units[0]["revision"])
	_main._on_code_rerun(uid0)
	_record("重新运行版本号 +1", int(_main.units[0]["revision"]) == rev0 + 1, str(_main.units[0]["revision"]))
	_record("重新运行后程序没停住", not _main.units[0]["controller"].halted(), _main.units[0]["controller"].last_error())
	var own_count: int = _main.team_units(0).size()
	_record("面板只列本方单位", panel.unit_list.item_count == own_count, "%d vs %d" % [panel.unit_list.item_count, own_count])
	_record("面板不列敌方单位", own_count < _main.units.size() or _main.team_units(1).is_empty(), str(_main.units.size()))

	var uid: int = int(_main.units[0]["uid"])
	# 先应用一份有语法错误的代码
	_main._on_code_applied(uid, "while True:\n    x = 1 +\n")
	var controller = _main.units[0]["controller"]
	_record("语法错误会让程序停住", controller.halted(), "没停住")
	_record("错误信息里有行号", controller.last_error().find("第") >= 0, controller.last_error())
	_record("面板显示错误", panel.error_label.text.find("代码出错") >= 0, panel.error_label.text)

	# 再应用一份正确代码
	_main._on_code_applied(uid, "while True:\n    set_lift(0.8)\n    drill(False)\n")
	controller.tick(0.5)
	_record("改对之后恢复运行", not controller.halted(), controller.last_error())
	_record("新代码的控制量生效", is_equal_approx(float(_main.units[0]["unit"].controls["lift"]), 0.8), str(_main.units[0]["unit"].controls))

	# print 输出能显示在面板里
	_main._on_code_applied(uid, "print(123)\nwhile True:\n    pass\n")
	controller.tick(0.2)
	panel.show_logs(controller.logs)
	_record("print 输出进入日志", panel.log_label.text.find("123") >= 0, panel.log_label.text)

	# 屏幕射线能选中本方单位，选不到敌方单位
	var mine: Array = _main.team_units(0)
	var my_unit = mine[0]["unit"]
	var my_screen: Vector2 = _main.rig.camera.unproject_position(my_unit.global_position)
	var picked: Dictionary = _main._pick_own_unit(my_screen)
	_record("屏幕射线能选中本方单位", int(picked.get("uid", -1)) == int(mine[0]["uid"]), str(my_screen))
	var red_units: Array = _main.team_units(1)
	if not red_units.is_empty():
		var red = red_units[0]["unit"]
		var red_screen: Vector2 = _main.rig.camera.unproject_position(red.global_position)
		_record("点敌方单位不会被当成自己的", _main._pick_own_unit(red_screen).is_empty(), str(red_screen))

	# 双击本方单位 → 打开面板并定位到这一台
	panel.close()
	var target_uid: int = int(mine[mine.size() - 1]["uid"])
	_main._open_code_for(target_uid)
	_record("双击单位会打开面板", panel.is_open(), "没打开")
	_record("面板定位到被点的单位", panel.current_uid() == target_uid, "%d vs %d" % [panel.current_uid(), target_uid])
	_record("编辑器里是该单位的代码", panel.editor.text == str(mine[mine.size() - 1]["code"]), "代码不一致")
	panel.close()

	# 关闭后恢复操作
	panel.close()
	_record("关闭面板后相机恢复", _main.rig.input_enabled, "相机仍未恢复")

	# 版本号递增
	var rev_before: int = int(_main.units[0]["revision"])
	_main._on_code_applied(uid, "while True:\n    pass\n")
	_record("每次应用版本号 +1", int(_main.units[0]["revision"]) == rev_before + 1, str(_main.units[0]["revision"]))

	# 面板在右侧，屏幕左上角的鼠标不算"压在面板上"（滚轮应该还能调视野）
	_record("面板打开时鼠标不在面板上", _main.code_panel.is_open() and not _main.code_panel.mouse_over())

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + item)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
