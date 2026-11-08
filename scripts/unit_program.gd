extends RefCounted
## 单位程序门面：给一个单位的一个"大脑"创建独立的执行环境。
##
## 每个控制中心（brain）都是独立实例，互不共享变量；mem 在程序重跑后保留。

const VM = preload("res://scripts/lang/py_vm.gd")

var _vm: VM
var _links: Array = []


func load_source(source: String) -> String:
	_vm = VM.new()
	_vm.load_source(source)
	_links = []
	return _vm.error


func set_links(rows: Array) -> void:
	_links = rows
	if _vm != null:
		_vm.set_parts(_links)


## 跑一步，返回 {ok, error, logs, drive, spin, steer, thrust, done}。
func step(readings: Dictionary, max_lines: int = 1) -> Dictionary:
	if _vm == null:
		return {"ok": false, "error": "程序未加载", "logs": [], "drive": 0.0, "spin": {}, "steer": {}, "thrust": {}, "done": true}
	_vm.set_parts(_links)
	_vm.inject(readings)
	var result: Dictionary = _vm.step(max_lines)
	if bool(result.get("done", false)) and bool(result.get("ok", false)):
		_vm.restart()
	return result
