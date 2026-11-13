extends RefCounted
## 本地 Python 模式：起一个 python 子进程（tools/py_harness.py），
## 通过 127.0.0.1 上的 TCP + 行分隔 JSON 通信。
## 玩家代码跑在玩家自己的 Python 里，可以装包、用完整语法；因此**不做沙箱**，
## 只在朋友局里用，联机正式对局仍然走内置 VM。

var server: TCPServer
var peer: StreamPeerTCP = null
var pid := -1
var port := 0
var last_error := ""

var _rx := ""


## 找一个可用的 python3（找不到返回空串）
static func python_path() -> String:
	var candidates: Array = [
		"/opt/homebrew/bin/python3",
		"/usr/local/bin/python3",
		"/usr/bin/python3",
		"/usr/bin/python",
	]
	var env := OS.get_environment("DSH_PYTHON")
	if env != "":
		candidates.push_front(env)
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return ""


func start() -> String:
	var py := python_path()
	if py == "":
		last_error = "系统里找不到 python3"
		return last_error
	var harness := ProjectSettings.globalize_path("res://tools/py_harness.py")
	if not FileAccess.file_exists(harness):
		last_error = "找不到 tools/py_harness.py"
		return last_error
	server = TCPServer.new()
	var bound := false
	for attempt in 40:
		var candidate: int = 27100 + int(Time.get_ticks_usec() % 4000) + attempt
		if server.listen(candidate, "127.0.0.1") == OK:
			port = candidate
			bound = true
			break
	if not bound:
		last_error = "没有可用端口"
		return last_error
	pid = OS.create_process(py, [harness, "--port", str(port)])
	if pid <= 0:
		last_error = "启动 python 失败"
		return last_error
	# 等它连回来（最多 3 秒）
	var deadline: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if server.is_connection_available():
			peer = server.take_connection()
			peer.set_no_delay(true)
			return ""
		OS.delay_msec(10)
	last_error = "python 没有连回来"
	return last_error


func is_ready() -> bool:
	return peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


## 让某个槽位加载/重载代码；返回错误字符串（空串表示成功）
func load_source(slot: int, src: String) -> String:
	if not is_ready():
		return "python 未连接"
	var reply := _exchange({"cmd": "load", "slot": slot, "src": src})
	if reply.is_empty():
		return "python 无响应"
	if bool(reply.get("ok", false)):
		return ""
	return str(reply.get("error", "编译失败"))


func step(slot: int, sensors: Dictionary, delta: float) -> Dictionary:
	if not is_ready():
		return {"ok": false, "error": "python 未连接", "controls": {}, "logs": []}
	var reply := _exchange({"cmd": "step", "slot": slot, "dt": delta, "sensors": sensors})
	if reply.is_empty():
		return {"ok": false, "error": "python 无响应", "controls": {}, "logs": []}
	return reply


func stop() -> void:
	if is_ready():
		_send_line({"cmd": "quit"})
	if peer != null:
		peer.disconnect_from_host()
		peer = null
	if server != null:
		server.stop()
		server = null
	if pid > 0:
		OS.kill(pid)
		pid = -1


func _send_line(payload: Dictionary) -> void:
	if peer == null:
		return
	var data: PackedByteArray = (JSON.stringify(payload) + "\n").to_utf8_buffer()
	peer.put_data(data)


func _exchange(payload: Dictionary) -> Dictionary:
	_send_line(payload)
	var deadline: int = Time.get_ticks_msec() + 120
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			last_error = "python 断开了"
			return {}
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_data(available)
			if int(chunk[0]) != OK:
				return {}
			_rx += (chunk[1] as PackedByteArray).get_string_from_utf8()
			var cut := _rx.find("\n")
			if cut >= 0:
				var line := _rx.substr(0, cut)
				_rx = _rx.substr(cut + 1)
				var parsed = JSON.parse_string(line)
				if parsed is Dictionary:
					return parsed
				return {}
		OS.delay_msec(1)
	last_error = "python 响应超时"
	return {}
