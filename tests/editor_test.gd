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
	_record("面板打开时相机不响应输入", _main.rig.input_enabled == false, "相机仍可操作")
	_record("面板列出了单位", panel.unit_list.item_count == _main.units.size(), str(panel.unit_list.item_count))

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

	# 关闭后恢复操作
	panel.close()
	_record("关闭面板后相机恢复", _main.rig.input_enabled, "相机仍未恢复")

	# 版本号递增
	var rev_before: int = int(_main.units[0]["revision"])
	_main._on_code_applied(uid, "while True:\n    pass\n")
	_record("每次应用版本号 +1", int(_main.units[0]["revision"]) == rev_before + 1, str(_main.units[0]["revision"]))

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
