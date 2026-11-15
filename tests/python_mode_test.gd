extends SceneTree
## 本地 Python 模式：桥接进程 + 控制器挂载（没有 python3 时整体跳过）

var _passed := 0
var _failed := 0
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		_run()
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
	return false


func _run() -> void:
	var PyExecutor = load("res://scripts/lang/py_executor.gd")
	var py_path: String = PyExecutor.python_path()
	if py_path == "":
		print("（系统里没有 python3，跳过本地 Python 模式测试）")
		_record("找不到 python3 时优雅跳过", true, "")
		return
	_record("找到 python3", py_path != "", py_path)

	var bridge = PyExecutor.new()
	var err: String = bridge.start()
	_record("启动 python 桥接进程", err == "", err)
	if err != "":
		return

	# 1) 正常代码
	var load_err: String = bridge.load_source(1, "def loop():\n    set_lift(0.5)\n    print(\"hi\", pos.y)\n")
	_record("加载正常代码", load_err == "", load_err)
	var reply: Dictionary = bridge.step(1, {"pos": {"x": 1.0, "y": 7.5, "z": 2.0}, "vel": {"x": 0, "y": 0, "z": 0}}, 0.016)
	_record("step 返回 ok", bool(reply.get("ok", false)), str(reply.get("error", "")))
	_record("控制量 lift = 0.5", absf(float(reply.get("controls", {}).get("lift", 0.0)) - 0.5) < 0.001,
		str(reply.get("controls", {})))
	_record("print 输出被带回", "hi 7.5" in " ".join(reply.get("logs", [])), str(reply.get("logs", [])))

	# 2) 语法错误
	var bad: String = bridge.load_source(2, "def loop(:\n    pass\n")
	_record("语法错误有中文行号提示", bad.begins_with("第 "), bad)

	# 3) 运行时错误
	bridge.load_source(3, "def loop():\n    x = 1 / 0\n")
	var bad_reply: Dictionary = bridge.step(3, {}, 0.016)
	_record("运行时错误被捕获", not bool(bad_reply.get("ok", true)), str(bad_reply.get("error", "")))

	# 4) sensors 里的字典可以用点号访问
	bridge.load_source(4, "def loop():\n    set_altitude(pos.y + 1.0)\n")
	var r4: Dictionary = bridge.step(4, {"pos": {"x": 0.0, "y": 10.0, "z": 0.0}}, 0.016)
	_record("pos.y 点号访问可用", absf(float(r4.get("controls", {}).get("alt_target", 0.0)) - 11.0) < 0.001,
		str(r4.get("controls", {})))

	bridge.stop()

	# 5) 接到游戏里：toggle 后已有单位都挂上 python 槽位
	var toggle_err: String = _main._start_python_bridge()
	_record("main 能启动 python 桥", toggle_err == "", toggle_err)
	var blue: Array = _main.team_units(0)
	var attached := false
	for entry in blue:
		var controller = entry["controller"]
		if int(controller.py_slot) >= 0:
			attached = true
	_record("在场单位挂上 Python 槽位", attached or blue.is_empty(), "blue=%d" % blue.size())
	var hover_err := ""
	for entry in blue:
		var slot: int = int(entry["controller"].py_slot)
		if slot >= 0:
			hover_err = _main.py.load_source(slot, "def loop():\n    set_velocity(0.0, 0.0)\n    set_altitude(40.0)\n")
	_record("能在运行时替换 Python 代码", hover_err == "", hover_err)

	# 6) 协同/建造 API 走 RPC 桥（本地 Python 也能 mark / team_set / find_path / command / build_here）
	var slot0 := -1
	for entry in blue:
		if int(entry["controller"].py_slot) >= 0:
			slot0 = int(entry["controller"].py_slot)
			break
	if slot0 >= 0:
		var coop_err: String = _main.py.load_source(slot0, "def loop():\n    team_set(\"协作\", 42)\n    mark(pos.x + 6.0, pos.y, pos.z, \"敌人\")\n    team_set(\"路\", len(find_path(pos.x + 8.0, pos.y, pos.z)))\n")
		_record("协同代码能加载", coop_err == "", coop_err)
		var sensors: Dictionary = {}
		for entry in blue:
			if int(entry["controller"].py_slot) == slot0:
				sensors = entry["controller"]._sensor_payload(true)
				break
		var r: Dictionary = _main.py.step(slot0, sensors, 0.016)
		_record("协同代码执行无错", bool(r.get("ok", false)), str(r.get("error", "")))
		_record("team_set 写入队伍黑板", int(_main._board_for(0).get("协作", 0)) == 42,
			str(_main._board_for(0)))
		var marks: Array = _main._marks_for(0)
		var marked := false
		for m in marks:
			if str(m.get("tag", "")) == "敌人":
				marked = true
		_record("mark 写进全队标点", marked, str(marks))
		_record("find_path 返回航路", int(_main._board_for(0).get("路", 0)) >= 1,
			str(_main._board_for(0).get("路")))

		# build_here：给够资源后能从小地图上盖出一栋
		_main.economy.add("copper", 200)
		_main.economy.add("coal", 200)
		_main.economy.add("iron", 100)
		var before: int = _main.buildings.size()
		var build_err: String = _main.py.load_source(slot0, "def loop():\n    build_here(\"miner\")\n")
		_record("build_here 代码能加载", build_err == "", build_err)
		var r2: Dictionary = _main.py.step(slot0, sensors, 0.016)
		_record("build_here 执行无错", bool(r2.get("ok", false)), str(r2.get("error", "")))
		_record("build_here 真的盖出建筑", _main.buildings.size() > before,
			"%d -> %d" % [before, _main.buildings.size()])

		# command：给自己队伍的另一台单位下指令
		var ally_uid := -1
		for entry in blue:
			if int(entry["controller"].py_slot) != slot0:
				ally_uid = int(entry["unit"].get("uid"))
				break
		if ally_uid > 0:
			_main.py.load_source(slot0, "def loop():\n    command(%d, \"hold\", 40.0, 40.0, 40.0)\n" % ally_uid)
			var r3: Dictionary = _main.py.step(slot0, sensors, 0.016)
			_record("command 执行无错", bool(r3.get("ok", false)), str(r3.get("error", "")))
			var got := false
			for cmd in _main.unit_commands:
				if int(cmd.get("uid", 0)) == ally_uid and str(cmd.get("action", "")) == "hold":
					got = true
			_record("command 下达到了队友", got, str(_main.unit_commands))
		else:
			_record("command 下达到了队友", true, "（只有一台单位，跳过）")

	_main._stop_python_bridge()


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)
