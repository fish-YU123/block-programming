extends RefCounted
## AST -> 字节码。每条语句前插入 LINE 指令，虚拟机靠 LINE 计算"这一帧能跑几行"。

const Op = preload("res://scripts/lang/py_opcodes.gd")

var _chunks: Array = []
var _funcs: Array = []
var _fail := ""
var _loops: Array = []
var _in_func := false


func compile(body: Array) -> Dictionary:
	_chunks = []
	_funcs = []
	_fail = ""
	_loops = []
	_in_func = false
	var main := _new_chunk("<module>", [], [])
	_chunks.append(main)
	for stmt in body:
		_emit_stmt(stmt)
		if _fail != "":
			return {"ok": false, "error": "第 %d 行：%s" % [int(stmt.get("line", 0)), _fail]}
	_emit({"op": Op.RETURN, "line": _line_of_last()})
	return {"ok": true, "main": _chunks[0], "funcs": _funcs}


func _line_of_last() -> int:
	var code: Array = _chunks[0]["code"]
	if code.is_empty():
		return 1
	return int(code[code.size() - 1].get("line", 1))


func _new_chunk(name: String, params: Array, defaults: Array) -> Dictionary:
	return {"name": name, "params": params, "defaults": defaults, "code": [], "consts": [], "is_func": name != "<module>"}


func _cur() -> Dictionary:
	return _chunks[_chunks.size() - 1]


func _emit(ins: Dictionary) -> void:
	var code: Array = _cur()["code"]
	ins["idx"] = code.size()
	code.append(ins)


func _emit_op(op: int, line: int, a = null, b = null) -> int:
	var ins := {"op": op, "line": line}
	if a != null:
		ins["a"] = a
	if b != null:
		ins["b"] = b
	_emit(ins)
	return int(ins["idx"])


func _const(value, line: int) -> int:
	var consts: Array = _cur()["consts"]
	for i in consts.size():
		if _same(consts[i], value):
			return i
	consts.append(value)
	return consts.size() - 1


func _same(a, b) -> bool:
	if typeof(a) != typeof(b):
		# 1 和 1.0 视为不同常量，保持 Python 语义
		return false
	return a == b


func _patch(index: int, target) -> void:
	_cur()["code"][index]["a"] = target


func _here() -> int:
	return _cur()["code"].size()


# ---------------------------------------------------------------- 语句

func _emit_stmt(stmt: Dictionary) -> void:
	var line := int(stmt.get("line", 0))
	match str(stmt["t"]):
		"expr":
			_emit_op(Op.LINE, line)
			_emit_expr(stmt["v"])
			_emit_op(Op.POP, line)
		"assign":
			_emit_op(Op.LINE, line)
			_emit_assign(stmt, line)
		"augassign":
			_emit_op(Op.LINE, line)
			_emit_augassign(stmt, line)
		"if":
			_emit_op(Op.LINE, line)
			_emit_if(stmt, line)
		"while":
			_emit_op(Op.LINE, line)
			_emit_while(stmt, line)
		"for":
			_emit_op(Op.LINE, line)
			_emit_for(stmt, line)
		"break":
			_emit_op(Op.LINE, line)
			if _loops.is_empty():
				_fail = "break 只能写在循环里"
				return
			_loops[_loops.size() - 1]["breaks"].append(_emit_op(Op.JUMP, line))
		"continue":
			_emit_op(Op.LINE, line)
			if _loops.is_empty():
				_fail = "continue 只能写在循环里"
				return
			_loops[_loops.size() - 1]["continues"].append(_emit_op(Op.JUMP, line))
		"return":
			_emit_op(Op.LINE, line)
			if not _in_func:
				_fail = "return 只能写在函数里"
				return
			if stmt.get("v") == null:
				_emit_op(Op.CONST, line, _const(null, line))
			else:
				_emit_expr(stmt["v"])
			_emit_op(Op.RETURN, line)
		"pass":
			_emit_op(Op.LINE, line)
		"def":
			_emit_def(stmt, line)
		_:
			_fail = "不支持的语句 %s" % str(stmt["t"])


func _emit_assign(stmt: Dictionary, line: int) -> void:
	var targets: Array = stmt["targets"]
	_emit_expr(stmt["v"])
	for i in range(targets.size() - 1, -1, -1):
		if i != targets.size() - 1:
			_emit_op(Op.DUP, line)
		_store_target(targets[i], line)


func _emit_augassign(stmt: Dictionary, line: int) -> void:
	var target: Dictionary = stmt["target"]
	var op := str(stmt["op"])
	var kind := str(target.get("t", ""))
	if kind == "name":
		_emit_op(Op.LOAD, line, str(target["v"]))
		_emit_expr(stmt["v"])
		_emit_op(Op.BIN, line, op)
		_emit_op(Op.STORE, line, str(target["v"]))
		return
	if kind == "attr":
		_emit_expr(target["o"])
		_emit_expr(stmt["v"])
		_emit_op(Op.AUG_ATTR, line, str(target["a"]), op)
		return
	if kind == "item":
		_emit_expr(target["o"])
		_emit_expr(target["i"])
		_emit_expr(stmt["v"])
		_emit_op(Op.AUG_ITEM, line, op)
		return
	_fail = "不支持这种增强赋值目标"


func _store_target(node: Dictionary, line: int) -> void:
	match str(node.get("t", "")):
		"name":
			_emit_op(Op.STORE, line, str(node["v"]))
		"attr":
			_emit_expr(node["o"])
			_emit_op(Op.STORE_ATTR, line, str(node["a"]))
		"item":
			_emit_expr(node["o"])
			_emit_expr(node["i"])
			_emit_op(Op.SET_ITEM, line)
		"tuple":
			var items: Array = node["e"]
			_emit_op(Op.UNPACK, line, items.size())
			for i in range(items.size() - 1, -1, -1):
				_store_target(items[i], line)
		_:
			_fail = "不能赋值给 %s" % str(node.get("t", ""))


func _emit_if(stmt: Dictionary, line: int) -> void:
	var branches: Array = stmt["branches"]
	var end_jumps: Array = []
	for branch in branches:
		var cond = branch[0]
		var body: Array = branch[1]
		_emit_expr(cond)
		var jf := _emit_op(Op.JF, int(cond.get("line", line)))
		for inner in body:
			_emit_stmt(inner)
			if _fail != "":
				return
		end_jumps.append(_emit_op(Op.JUMP, line))
		_patch(jf, _here())
	var orelse: Array = stmt["orelse"]
	for inner in orelse:
		_emit_stmt(inner)
		if _fail != "":
			return
	var end := _here()
	for jump in end_jumps:
		_patch(int(jump), end)


func _emit_while(stmt: Dictionary, line: int) -> void:
	var start := _here()
	_emit_expr(stmt["test"])
	var jf := _emit_op(Op.JF, int(stmt["test"].get("line", line)))
	_loops.append({"breaks": [], "continues": [], "continue_target": start})
	for inner in stmt["body"]:
		_emit_stmt(inner)
		if _fail != "":
			return
	_emit_op(Op.JUMP, line, start)
	var ctx: Dictionary = _loops[_loops.size() - 1]
	_loops.pop_back()
	_patch(jf, _here())
	for jump in ctx["breaks"]:
		_patch(int(jump), _here())
	for jump in ctx["continues"]:
		_patch(int(jump), start)


func _emit_for(stmt: Dictionary, line: int) -> void:
	_emit_expr(stmt["iter"])
	_emit_op(Op.ITER, line)
	var loop_start := _here()
	var for_next := _emit_op(Op.FOR_NEXT, line)
	_loops.append({"breaks": [], "continues": [], "continue_target": loop_start})
	_store_target(stmt["target"], line)
	for inner in stmt["body"]:
		_emit_stmt(inner)
		if _fail != "":
			return
	_emit_op(Op.JUMP, line, loop_start)
	var ctx: Dictionary = _loops[_loops.size() - 1]
	_loops.pop_back()
	var end := _here()
	_patch(for_next, end)
	for jump in ctx["breaks"]:
		_patch(int(jump), end)
	for jump in ctx["continues"]:
		_patch(int(jump), loop_start)


func _emit_def(stmt: Dictionary, line: int) -> void:
	var name := str(stmt["name"])
	var params: Array = stmt["params"]
	var defaults_ast: Array = stmt["defaults"]
	var defaults: Array = []
	for i in params.size():
		if i < defaults_ast.size() and defaults_ast[i] != null:
			var literal = _literal_value(defaults_ast[i])
			if literal == null and defaults_ast[i].get("t") != "const":
				_fail = "第 %d 行：参数默认值只能是数字、字符串或 True/False/None" % int(defaults_ast[i].get("line", line))
				return
			defaults.append(literal)
		elif i < defaults_ast.size():
			defaults.append(null)
	var chunk := _new_chunk(name, params, defaults)
	_funcs.append(chunk)
	var func_index := _funcs.size() - 1
	_chunks.append(chunk)
	var was_in_func := _in_func
	var saved_loops := _loops
	_in_func = true
	_loops = []
	for inner in stmt["body"]:
		_emit_stmt(inner)
		if _fail != "":
			return
	_emit_op(Op.CONST, line, _const(null, line))
	_emit_op(Op.RETURN, line)
	_in_func = was_in_func
	_loops = saved_loops
	_chunks.pop_back()
	_emit_op(Op.FUNC, line, func_index)
	_emit_op(Op.STORE, line, name)


func _literal_value(node: Dictionary):
	match str(node.get("t", "")):
		"num", "str", "const":
			return node["v"]
		"un":
			var inner = _literal_value(node["e"])
			if inner == null:
				return null
			if str(node["op"]) == "-":
				return -inner
			if str(node["op"]) == "~":
				return ~int(inner)
			return inner
	return null


# ---------------------------------------------------------------- 表达式

func _emit_expr(node: Dictionary) -> void:
	var line := int(node.get("line", 0))
	match str(node.get("t", "")):
		"num", "str", "const":
			_emit_op(Op.CONST, line, _const(node["v"], line))
		"name":
			_emit_op(Op.LOAD, line, str(node["v"]))
		"bin":
			_emit_expr(node["l"])
			_emit_expr(node["r"])
			_emit_op(Op.BIN, line, str(node["op"]))
		"un":
			_emit_expr(node["e"])
			_emit_op(Op.UNARY, line, str(node["op"]))
		"cmp":
			_emit_expr(node["l"])
			_emit_expr(node["r"])
			_emit_op(Op.CMP, line, str(node["op"]))
		"not":
			_emit_expr(node["e"])
			_emit_op(Op.UNARY, line, "not")
		"bool":
			_emit_expr(node["l"])
			_emit_op(Op.DUP, line)
			var jump := -1
			if str(node["op"]) == "and":
				jump = _emit_op(Op.JF, line)
			else:
				jump = _emit_op(Op.JT, line)
			_emit_op(Op.POP, line)
			_emit_expr(node["r"])
			_patch(jump, _here())
		"call":
			_emit_expr(node["f"])
			var args: Array = node["args"]
			for arg in args:
				_emit_expr(arg)
			_emit_op(Op.CALL, line, args.size())
		"attr":
			_emit_expr(node["o"])
			_emit_op(Op.LOAD_ATTR, line, str(node["a"]))
		"item":
			_emit_expr(node["o"])
			_emit_expr(node["i"])
			_emit_op(Op.GET_ITEM, line)
		"list":
			var elems: Array = node["e"]
			for elem in elems:
				_emit_expr(elem)
			_emit_op(Op.BUILD_LIST, line, elems.size())
		"tuple":
			var items: Array = node["e"]
			for item in items:
				_emit_expr(item)
			_emit_op(Op.BUILD_LIST, line, items.size())
		"dict":
			var keys: Array = node["k"]
			var values: Array = node["v"]
			for i in keys.size():
				_emit_expr(keys[i])
				_emit_expr(values[i])
			_emit_op(Op.BUILD_DICT, line, keys.size())
		_:
			_fail = "不支持的表达式 %s" % str(node.get("t", ""))
