extends SceneTree
## 沙箱 VM 回归测试：headless 运行
##   godot --headless --path . --script res://tests/lang_test.gd

const VM = preload("res://scripts/lang/py_vm.gd")

var _passed := 0
var _failed := 0
var _failures: Array = []


func _initialize() -> void:
	_test_arith()
	_test_loop()
	_test_while()
	_test_func()
	_test_container()
	_test_part()
	_test_error_line()
	_test_infinite_guard()
	_test_restart_mem()
	_test_chinese_names()
	_test_sensors()
	_test_bad_call()
	_test_controls()
	_test_compare_ops()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + str(item))
	quit(0 if _failed == 0 else 1)


# ---------------------------------------------------------------- 测试用例

func _test_arith() -> void:
	var run := _run("a = 1 + 2 * 3\nprint(a)\nprint(7 // 2)\nprint(7 / 2)\nprint(2 ** 10)\nprint(-7 // 2)\nprint(7 % 3)\nprint(\"x\" * 3)\n")
	_expect_logs("算术", run, ["7", "3", "3.5", "1024", "-4", "1", "xxx"])


func _test_loop() -> void:
	var run := _run("total = 0\nfor i in range(1, 6):\n    if i == 3:\n        continue\n    if i == 5:\n        break\n    total += i\nprint(total)\n")
	_expect_logs("循环", run, ["7"])


func _test_while() -> void:
	var run := _run("n = 0\nwhile n < 5:\n    n += 1\nprint(n)\n")
	_expect_logs("while", run, ["5"])


func _test_func() -> void:
	var run := _run("def add(a, b=10):\n    return a + b\nprint(add(1))\nprint(add(1, 2))\n")
	_expect_logs("函数", run, ["11", "3"])


func _test_container() -> void:
	var run := _run("xs = [3, 1, 2]\nxs[0] = 9\nd = {\"k\": 1}\nd[\"j\"] = 2\nprint(len(xs))\nprint(9 in xs)\nprint(\"z\" not in d)\nprint(d[\"j\"])\nprint(xs[9 - 8])\n")
	_expect_logs("列表字典", run, ["3", "True", "True", "2", "1"])


func _test_part() -> void:
	var links := [
		{"name": "wheel1", "kind": "wheel", "slot": 0},
		{"name": "propeller1", "kind": "propeller", "slot": 1},
	]
	var run := _run("w = get_link(1)\nw.speed = 2\nw.speed += 1\np = get_link(2)\np.thrust = 3\nprint(w.speed)\nprint(wheel1.speed)\nprint(p.thrust)\n", 200, links)
	_expect_no_error("部件", run)
	_expect_logs("部件", run, ["3.0", "3.0", "3.0"])
	var vm: VM = run["vm"]
	_expect_eq("部件 spin[0]", float(vm.state["spin"].get(0, 0.0)), 3.0)
	_expect_eq("部件 thrust[1]", float(vm.state["thrust"].get(1, 0.0)), 3.0)


func _test_error_line() -> void:
	var run := _run("x = 1\ny = x + \"a\"\n")
	var vm: VM = run["vm"]
	_expect_contains("错误行号", vm.error, "第 2 行")
	_expect_contains("错误类型", vm.error, "TypeError")


func _test_infinite_guard() -> void:
	var vm := VM.new()
	vm.load_source("while True:\n    pass\n")
	for i in 500:
		vm.step(1)
	_expect_eq("死循环被行预算限制", vm.error, "")
	_expect_eq("死循环不会结束", vm.finished, false)
	var vm2 := VM.new()
	vm2.load_source("x = \"a\" * 10000000\n")
	vm2.step(1)
	_expect_contains("单行内存保护", vm2.error, "MemoryError")


func _test_restart_mem() -> void:
	var vm := VM.new()
	vm.load_source("if \"n\" in mem:\n    mem[\"n\"] += 1\nelse:\n    mem[\"n\"] = 1\nprint(mem[\"n\"])\n")
	var logs: Array = []
	for i in 400:
		vm.inject({})
		var result := vm.step(1)
		for line in result["logs"]:
			logs.append(str(line))
		if vm.error != "":
			break
		if vm.finished:
			vm.restart()
	if logs.size() < 3:
		_record("重启保留 mem", false, "只跑了 %d 轮" % logs.size())
	else:
		_expect_eq("重启保留 mem 第一轮", str(logs[0]), "1")
		_expect_eq("重启保留 mem 第二轮", str(logs[1]), "2")
		_expect_eq("重启保留 mem 第三轮", str(logs[2]), "3")


func _test_chinese_names() -> void:
	var run := _run("速度 = 2\n偏移 = 速度 * 3\nprint(偏移)\n")
	_expect_logs("中文标识符", run, ["6"])


func _test_sensors() -> void:
	var run := _run("print(energy)\nprint(px)\nif energy > 1 and px < 2:\n    set_drive(0.5)\n", 50, [], {"energy": 5.0, "px": 1.0})
	_expect_no_error("传感器", run)
	_expect_logs("传感器", run, ["5.0", "1.0"])
	_expect_eq("传感器 drive", float((run["vm"] as VM).state["drive"]), 0.5)


func _test_bad_call() -> void:
	var run := _run("set_drive(\"x\")\n")
	_expect_contains("参数类型", (run["vm"] as VM).error, "TypeError")


func _test_compare_ops() -> void:
	var run := _run("print(1 < 2)\nprint(2 <= 2)\nprint(\"abc\" == \"abc\")\nprint([1, 2] == [1, 2])\nprint(1 == 1.0)\nprint(not True)\n")
	_expect_logs("比较", run, ["True", "True", "True", "True", "True", "False"])


# ---------------------------------------------------------------- 工具

func _run(source: String, max_steps: int = 200, links: Array = [], readings: Dictionary = {}) -> Dictionary:
	var vm := VM.new()
	vm.set_parts(links)
	vm.load_source(source)
	var logs: Array = []
	for i in max_steps:
		if vm.finished:
			break
		vm.inject(readings)
		var result := vm.step(1)
		for line in result["logs"]:
			logs.append(str(line))
		if vm.error != "":
			break
	return {"vm": vm, "logs": logs}


func _test_controls() -> void:
	var run := _run("set_lift(0.8)\nset_tilt(0.2, -0.3)\nset_rcs(-1, 0.5)\ndrill()\n")
	_expect_no_error("飞飞控制接口", run)
	var controls: Dictionary = run["vm"].state["controls"]
	_expect_eq("set_lift", controls["lift"], 0.8)
	_expect_eq("set_tilt 前后", controls["pitch"], 0.2)
	_expect_eq("set_tilt 左右", controls["roll"], -0.3)
	_expect_eq("set_rcs 转向", controls["turn"], -1.0)
	_expect_eq("set_rcs 前后", controls["forward"], 0.5)
	_expect_eq("drill 开", controls["drill"], true)
	var run2 := _run("set_lift(5)\nset_tilt(-3, 3)\n")
	_expect_eq("set_lift 夹到 1", run2["vm"].state["controls"]["lift"], 1.0)
	_expect_eq("set_tilt 夹到 -1", run2["vm"].state["controls"]["pitch"], -1.0)
	_expect_eq("set_tilt 夹到 1", run2["vm"].state["controls"]["roll"], 1.0)
	var run3 := _run("print(pos.y)\nprint(blocks[1][1])\nprint(heights[0][0])\n", 50, [], {"pos": {"x": 1.0, "y": 2.0, "z": 3.0}, "blocks": [["grass", "grass", "grass"], ["grass", "stone", "grass"], ["grass", "grass", "grass"]], "heights": [[26, 26, 26], [26, 25, 26], [26, 26, 26]]})
	_expect_logs("传感器字典属性访问", _only_logs(run3, 3), ["2.0", "stone", "26"])


func _only_logs(run: Dictionary, count: int) -> Dictionary:
	var logs: Array = run["logs"]
	if logs.size() > count:
		logs = logs.slice(logs.size() - count)
	return {"vm": run["vm"], "logs": logs}


func _expect_logs(name: String, run: Dictionary, expected: Array) -> void:
	var vm: VM = run["vm"]
	if vm.error != "":
		_record(name, false, "运行出错：" + vm.error)
		return
	var actual: Array = []
	for line in run["logs"]:
		actual.append(str(line))
	var a := "\n".join(actual)
	var b := "\n".join(expected)
	_record(name, a == b, "期望 [%s] 实际 [%s]" % [b, a])


func _expect_no_error(name: String, run: Dictionary) -> void:
	var vm: VM = run["vm"]
	_record(name + " 无错误", vm.error == "", vm.error)


func _expect_contains(name: String, actual: String, needle: String) -> void:
	_record(name, actual.find(needle) >= 0, "期望包含「%s」实际「%s」" % [needle, actual])


func _expect_eq(name: String, actual, expected) -> void:
	_record(name, actual == expected, "期望 %s 实际 %s" % [str(expected), str(actual)])


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
