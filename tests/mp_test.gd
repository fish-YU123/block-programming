extends SceneTree
## M6 联机端到端测试：同一进程里开一个主机 + 一个客户端，走真实 UDP 回环。

const MpManager = preload("res://scripts/net/mp_manager.gd")

const TEST_PORT := 27201

var _main: Node
var client_mp: MpManager
var client_root: Node3D
var _frames := 0
var _passed := 0
var _failed := 0
var _host: MpManager
var _got_code: Array = []
var _phase := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	_host = _main.mp
	if _frames == 3:
		# 1) 主机开房间
		var err: String = _host.host_game(TEST_PORT)
		_record("主机开房间", err == "" and _host.is_host(), err)

		# 2) 客户端加入
		client_mp = MpManager.new()
		client_mp.name = "ClientMp"
		root.add_child(client_mp)
		client_root = Node3D.new()
		root.add_child(client_root)
		client_mp.world = _main.world
		client_mp.replicas_root = client_root
		client_mp.unit_def = _main.unit_db.get_def("feifei")
		var join_err: String = client_mp.join_game("127.0.0.1", TEST_PORT)
		_record("客户端发起连接", join_err == "", join_err)
		return false

	client_mp.tick(delta)

	# 3) 客户端应收到 WELCOME（队伍 = 红方 1）
	if _phase == 0 and _frames > 20:
		_phase = 1
		_record("客户端收到欢迎消息", client_mp.my_team == 1, "team=%d" % client_mp.my_team)
		_record("主机侧有会话", _host.session.get_sessions().size() >= 1, str(_host.session.get_sessions()))

	# 4) 等几帧快照，客户端应该出现替身
	if _phase == 1 and _frames > 60:
		_phase = 2
		var reps: Array = client_mp.replicas()
		var alive := 0
		for entry in _main.units:
			if entry["unit"].alive:
				alive += 1
		_record("客户端收到快照并生成替身", reps.size() >= 1, "替身 %d 个" % reps.size())
		_record("替身数量不超过主机单位数", reps.size() <= alive, "%d > %d" % [reps.size(), alive])
		# 替身位置应该在世界范围内
		if reps.size() > 0:
			var p: Vector3 = reps[0]["node"].global_position
			_record("替身位置合理", p.x > 0.0 and p.x < 256.0 and p.z > 0.0 and p.z < 256.0, str(p))

		# 5) 客户端上报代码 → 主机收到并绑定
		_host.code_from_client.connect(func(uid, revision, source): _got_code.append({"uid": uid, "rev": revision, "src": source}))
		var target_uid: int = int(reps[0]["uid"]) if reps.size() > 0 else 0
		client_mp.send_code(target_uid, 7, "def loop():\n    set_lift(0.5)\n")
		_phase = 3

	if _phase == 3 and _frames > 90:
		_phase = 4
		_record("主机收到客户端代码", _got_code.size() == 1, str(_got_code))
		if _got_code.size() == 1:
			var uid := int(_got_code[0]["uid"])
			var entry: Dictionary = _main._entry_by_uid(uid)
			_record("代码绑定到对应单位", not entry.is_empty(), "uid=%d" % uid)
			if not entry.is_empty():
				_record("单位代码已更新", str(entry["code"]).find("set_lift(0.5)") >= 0, str(entry["code"]))
				_record("单位版本号已更新", int(entry["revision"]) == 7, str(entry["revision"]))

		# 6) 断开
		client_mp.stop()
		_host.stop()
		_record("断开后状态复位", not _host.is_host() and not client_mp.is_client())

		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
	return false
