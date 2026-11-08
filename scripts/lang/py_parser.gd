extends RefCounted
## 单位代码语法分析器：token 流 -> AST（字典形式）。
## 支持 Python 子集：赋值/增强赋值、if/elif/else、while、for-in、
## def/return、break/continue/pass、列表/字典字面量、属性与下标。

const Lexer = preload("res://scripts/lang/py_lexer.gd")

const AUG_OPS := ["+=", "-=", "*=", "/=", "%=", "//=", "**="]
const CMP_OPS := ["==", "!=", "<", ">", "<=", ">="]

var _toks: Array = []
var _pos := 0
var _fail := ""
## 解析 for 的循环变量时不要吃掉 in
var _no_in := false


func parse(src: String) -> Dictionary:
	var lex := Lexer.new()
	var lexed := lex.tokenize(src)
	if not bool(lexed.get("ok", false)):
		return {"ok": false, "error": str(lexed.get("error", "语法错误"))}
	_toks = lexed["tokens"]
	_pos = 0
	_fail = ""
	var body := _parse_block_top()
	if _fail != "":
		return {"ok": false, "error": _fail}
	return {"ok": true, "body": body}


# ---------------------------------------------------------------- 基础工具

func _peek() -> Dictionary:
	if _pos >= _toks.size():
		return {"t": Lexer.T_EOF, "v": "", "line": 0}
	return _toks[_pos]


func _line() -> int:
	return int(_peek().get("line", 0))


func _name_at(offset: int, value: String) -> bool:
	var index := _pos + offset
	if index < 0 or index >= _toks.size():
		return false
	var tok: Dictionary = _toks[index]
	return int(tok["t"]) == Lexer.T_NAME and str(tok["v"]) == value


func _at_end() -> bool:
	return int(_peek()["t"]) == Lexer.T_EOF


func _at(kind: int, value) -> bool:
	var tok := _peek()
	return int(tok["t"]) == kind and tok["v"] == value


func _at_name(value: String) -> bool:
	return _at(Lexer.T_NAME, value)


func _at_op(value: String) -> bool:
	return _at(Lexer.T_OP, value)


func _advance() -> Dictionary:
	var tok := _peek()
	_pos += 1
	return tok


func _skip_newlines() -> void:
	while int(_peek()["t"]) == Lexer.T_NEWLINE:
		_pos += 1


func _expect_op(value: String) -> bool:
	if _at_op(value):
		_pos += 1
		return true
	_set_error("第 %d 行：这里应该是 '%s'，实际是 '%s'" % [_line(), value, str(_peek()["v"])])
	return false


func _expect_name() -> String:
	var tok := _peek()
	if int(tok["t"]) == Lexer.T_NAME:
		_pos += 1
		return str(tok["v"])
	_set_error("第 %d 行：这里应该是一个名字" % _line())
	return ""


func _expect_newline() -> void:
	if int(_peek()["t"]) == Lexer.T_NEWLINE:
		_pos += 1
		return
	if _at_end():
		return
	_set_error("第 %d 行：这一行末尾有多余的内容 '%s'" % [_line(), str(_peek()["v"])])


func _skip_newlines_if_any() -> void:
	if int(_peek()["t"]) == Lexer.T_NEWLINE:
		_pos += 1


func _set_error(message: String) -> void:
	if _fail == "":
		_fail = message


# ---------------------------------------------------------------- 语句

func _parse_block_top() -> Array:
	var body: Array = []
	_skip_newlines()
	while not _at_end():
		var stmt = _parse_statement()
		if _fail != "":
			return []
		if stmt != null:
			body.append(stmt)
		_skip_newlines()
	return body


func _parse_statement():
	var tok := _peek()
	if int(tok["t"]) == Lexer.T_NAME:
		var word := str(tok["v"])
		if word == "if":
			return _parse_if()
		if word == "while":
			return _parse_while()
		if word == "for":
			return _parse_for()
		if word == "def":
			return _parse_def()
		if word == "return":
			_pos += 1
			var value = null
			if int(_peek()["t"]) != Lexer.T_NEWLINE and not _at_end():
				value = _parse_expr()
				if _fail != "":
					return null
			_expect_newline()
			return {"t": "return", "v": value, "line": int(tok["line"])}
		if word == "break" or word == "continue" or word == "pass":
			_pos += 1
			_expect_newline()
			return {"t": word, "line": int(tok["line"])}
	if int(tok["t"]) == Lexer.T_OP and str(tok["v"]) == ";":
		return null
	return _parse_simple()


func _parse_simple():
	var start_line := _line()
	var first = _parse_expr()
	if _fail != "":
		return null
	if _at_op(","):
		first = _parse_tuple_tail(first)
		if _fail != "":
			return null
	# 赋值链：a = b = expr
	if _at_op("="):
		var targets: Array = [_as_target(first)]
		while _at_op("="):
			_pos += 1
			var value = _parse_expr()
			if _fail != "":
				return null
			if _at_op(","):
				value = _parse_tuple_tail(value)
				if _fail != "":
					return null
			if _at_op("="):
				targets.append(_as_target(value))
				continue
			_expect_newline()
			return {"t": "assign", "targets": targets, "v": value, "line": start_line}
		return null
	var tok := _peek()
	if int(tok["t"]) == Lexer.T_OP and AUG_OPS.has(str(tok["v"])):
		var op := str(tok["v"])
		_pos += 1
		var value = _parse_expr()
		if _fail != "":
			return null
		_expect_newline()
		return {
			"t": "augassign",
			"target": _as_target(first),
			"op": op.substr(0, op.length() - 1),
			"v": value,
			"line": start_line,
		}
	_expect_newline()
	return {"t": "expr", "v": first, "line": start_line}


## 逗号分隔的表达式序列（元组），遇到 = 或行尾就停
func _parse_tuple_tail(first):
	var line := int(first.get("line", 0))
	var items: Array = [first]
	while _at_op(","):
		_pos += 1
		if _at_op("=") or int(_peek()["t"]) == Lexer.T_NEWLINE or _at_end():
			break
		items.append(_parse_expr())
		if _fail != "":
			return first
	return {"t": "tuple", "e": items, "line": line}


func _as_target(node):
	var kind := str(node.get("t", ""))
	if kind == "name" or kind == "attr" or kind == "item":
		return node
	if kind == "tuple":
		var items: Array = []
		for item in node["e"]:
			var sub = _as_target(item)
			if sub == null:
				return null
			items.append(sub)
		node["e"] = items
		return node
	_set_error("第 %d 行：不能给这个表达式赋值" % int(node.get("line", _line())))
	return null


func _parse_if():
	var line := _line()
	_pos += 1
	var branches: Array = []
	var test = _parse_expr()
	if _fail != "":
		return null
	_expect_op(":")
	var body := _parse_block()
	if _fail != "":
		return null
	branches.append([test, body])
	var orelse: Array = []
	while _at_name("elif"):
		_pos += 1
		var test2 = _parse_expr()
		if _fail != "":
			return null
		_expect_op(":")
		var body2 := _parse_block()
		if _fail != "":
			return null
		branches.append([test2, body2])
	if _at_name("else"):
		_pos += 1
		_expect_op(":")
		orelse = _parse_block()
		if _fail != "":
			return null
	return {"t": "if", "branches": branches, "orelse": orelse, "line": line}


func _parse_while():
	var line := _line()
	_pos += 1
	var test = _parse_expr()
	if _fail != "":
		return null
	_expect_op(":")
	var body := _parse_block()
	if _fail != "":
		return null
	return {"t": "while", "test": test, "body": body, "line": line}


func _parse_for():
	var line := _line()
	_pos += 1
	_no_in = true
	var target_node = _parse_target_list()
	_no_in = false
	if _fail != "":
		return null
	if not _at_name("in"):
		_set_error("第 %d 行：for 后面缺少 in" % _line())
		return null
	_pos += 1
	var iter_node = _parse_expr()
	if _fail != "":
		return null
	_expect_op(":")
	var body := _parse_block()
	if _fail != "":
		return null
	return {"t": "for", "target": _as_target(target_node), "iter": iter_node, "body": body, "line": line}


func _parse_target_list():
	var first = _parse_expr()
	if _fail != "":
		return null
	if not _at_op(","):
		return first
	var items: Array = [first]
	while _at_op(","):
		_pos += 1
		if _at_name("in"):
			break
		items.append(_parse_expr())
		if _fail != "":
			return null
	return {"t": "tuple", "e": items, "line": int(first.get("line", 0))}


func _parse_def():
	var line := _line()
	_pos += 1
	var name := _expect_name()
	if _fail != "":
		return null
	if not _expect_op("("):
		return null
	var params: Array = []
	var defaults: Array = []
	if not _at_op(")"):
		while true:
			var param := _expect_name()
			if _fail != "":
				return null
			params.append(param)
			if _at_op("="):
				_pos += 1
				var default = _parse_expr()
				if _fail != "":
					return null
				while defaults.size() < params.size() - 1:
					defaults.append(null)
				defaults.append(default)
			elif not defaults.is_empty():
				_set_error("第 %d 行：有默认值的参数后面不能再有无默认值的参数" % _line())
				return null
			if _at_op(","):
				_pos += 1
				if _at_op(")"):
					break
				continue
			break
	if not _expect_op(")"):
		return null
	_expect_op(":")
	var body := _parse_block()
	if _fail != "":
		return null
	return {"t": "def", "name": name, "params": params, "defaults": defaults, "body": body, "line": line}


## 解析一个缩进块（`:` 之后）
func _parse_block() -> Array:
	if int(_peek()["t"]) != Lexer.T_NEWLINE:
		# 允许 `if x: y = 1` 这种单行写法，但只解析一条语句
		var single = _parse_statement()
		if _fail != "" or single == null:
			return []
		return [single]
	_pos += 1
	_skip_newlines()
	if int(_peek()["t"]) != Lexer.T_INDENT:
		_set_error("第 %d 行：这里需要缩进的代码块" % _line())
		return []
	_pos += 1
	var body: Array = []
	_skip_newlines()
	while not _at_end():
		if int(_peek()["t"]) == Lexer.T_DEDENT:
			_pos += 1
			return body
		var stmt = _parse_statement()
		if _fail != "":
			return []
		if stmt != null:
			body.append(stmt)
		_skip_newlines()
	_set_error("第 %d 行：代码块没有正常结束" % _line())
	return body


# ---------------------------------------------------------------- 表达式

func _parse_expr():
	return _parse_or()


func _parse_or():
	var left = _parse_and()
	if _fail != "":
		return null
	while _at_name("or"):
		_pos += 1
		var right = _parse_and()
		if _fail != "":
			return null
		left = {"t": "bool", "op": "or", "l": left, "r": right, "line": int(left.get("line", 0))}
	return left


func _parse_and():
	var left = _parse_not()
	if _fail != "":
		return null
	while _at_name("and"):
		_pos += 1
		var right = _parse_not()
		if _fail != "":
			return null
		left = {"t": "bool", "op": "and", "l": left, "r": right, "line": int(left.get("line", 0))}
	return left


func _parse_not():
	if _at_name("not"):
		var line := _line()
		_pos += 1
		var inner = _parse_not()
		if _fail != "":
			return null
		return {"t": "not", "e": inner, "line": line}
	return _parse_cmp()


func _parse_cmp():
	var left = _parse_add()
	if _fail != "":
		return null
	var tok := _peek()
	if int(tok["t"]) == Lexer.T_OP and CMP_OPS.has(str(tok["v"])):
		var op := str(tok["v"])
		_pos += 1
		var right = _parse_add()
		if _fail != "":
			return null
		var after := _peek()
		if int(after["t"]) == Lexer.T_OP and CMP_OPS.has(str(after["v"])):
			_set_error("第 %d 行：不支持链式比较（a < b < c），请写成 a < b and b < c" % _line())
			return null
		return {"t": "cmp", "op": op, "l": left, "r": right, "line": int(left.get("line", 0))}
	# `x in y` / `x not in y`
	if not _no_in and (_at_name("in") or (_at_name("not") and _name_at(1, "in"))):
		var line := _line()
		var op2 := "in"
		if _at_name("not"):
			op2 = "not in"
			_pos += 1
		_pos += 1
		var right2 = _parse_add()
		if _fail != "":
			return null
		return {"t": "cmp", "op": op2, "l": left, "r": right2, "line": line}
	return left


func _parse_add():
	var left = _parse_mul()
	if _fail != "":
		return null
	while _at_op("+") or _at_op("-"):
		var op := str(_peek()["v"])
		_pos += 1
		var right = _parse_mul()
		if _fail != "":
			return null
		left = {"t": "bin", "op": op, "l": left, "r": right, "line": int(left.get("line", 0))}
	return left


func _parse_mul():
	var left = _parse_unary()
	if _fail != "":
		return null
	while _at_op("*") or _at_op("/") or _at_op("//") or _at_op("%"):
		var op := str(_peek()["v"])
		_pos += 1
		var right = _parse_unary()
		if _fail != "":
			return null
		left = {"t": "bin", "op": op, "l": left, "r": right, "line": int(left.get("line", 0))}
	return left


func _parse_unary():
	var tok := _peek()
	if int(tok["t"]) == Lexer.T_OP and (str(tok["v"]) == "-" or str(tok["v"]) == "+" or str(tok["v"]) == "~"):
		var op := str(tok["v"])
		_pos += 1
		var inner = _parse_unary()
		if _fail != "":
			return null
		if op == "+":
			return inner
		return {"t": "un", "op": op, "e": inner, "line": int(tok["line"])}
	return _parse_power()


func _parse_power():
	var base = _parse_postfix()
	if _fail != "":
		return null
	if _at_op("**"):
		_pos += 1
		var exponent = _parse_unary()
		if _fail != "":
			return null
		return {"t": "bin", "op": "**", "l": base, "r": exponent, "line": int(base.get("line", 0))}
	return base


func _parse_postfix():
	var node = _parse_atom()
	if _fail != "":
		return null
	while true:
		if _at_op("."):
			_pos += 1
			var attr := _expect_name()
			if _fail != "":
				return null
			node = {"t": "attr", "o": node, "a": attr, "line": int(node.get("line", 0))}
			continue
		if _at_op("("):
			_pos += 1
			var args: Array = []
			if not _at_op(")"):
				while true:
					# 不支持关键字参数
					if int(_peek()["t"]) == Lexer.T_NAME and int(_toks[min(_pos + 1, _toks.size() - 1)]["t"]) == Lexer.T_OP and str(_toks[min(_pos + 1, _toks.size() - 1)]["v"]) == "=":
						_set_error("第 %d 行：不支持关键字参数" % _line())
						return null
					var arg = _parse_expr()
					if _fail != "":
						return null
					args.append(arg)
					if _at_op(","):
						_pos += 1
						if _at_op(")"):
							break
						continue
					break
			if not _expect_op(")"):
				return null
			node = {"t": "call", "f": node, "args": args, "line": int(node.get("line", 0))}
			continue
		if _at_op("["):
			_pos += 1
			var index = _parse_expr()
			if _fail != "":
				return null
			if not _expect_op("]"):
				return null
			node = {"t": "item", "o": node, "i": index, "line": int(node.get("line", 0))}
			continue
		return node


func _parse_atom():
	var tok := _peek()
	var kind := int(tok["t"])
	var line := int(tok["line"])
	if kind == Lexer.T_NUM:
		_pos += 1
		return _number_node(str(tok["v"]), line)
	if kind == Lexer.T_STR:
		_pos += 1
		var text := str(tok["v"])
		while int(_peek()["t"]) == Lexer.T_STR:
			text += str(_peek()["v"])
			_pos += 1
		return {"t": "str", "v": text, "line": line}
	if kind == Lexer.T_NAME:
		var word := str(tok["v"])
		_pos += 1
		if word == "True":
			return {"t": "const", "v": true, "line": line}
		if word == "False":
			return {"t": "const", "v": false, "line": line}
		if word == "None":
			return {"t": "const", "v": null, "line": line}
		if word == "not":
			_set_error("第 %d 行：not 的位置不对" % line)
			return null
		return {"t": "name", "v": word, "line": line}
	if kind == Lexer.T_OP and str(tok["v"]) == "(":
		_pos += 1
		if _at_op(")"):
			_pos += 1
			return {"t": "tuple", "e": [], "line": line}
		var inner = _parse_expr()
		if _fail != "":
			return null
		if _at_op(","):
			var items: Array = [inner]
			while _at_op(","):
				_pos += 1
				if _at_op(")"):
					break
				items.append(_parse_expr())
				if _fail != "":
					return null
			if not _expect_op(")"):
				return null
			return {"t": "tuple", "e": items, "line": line}
		if not _expect_op(")"):
			return null
		return inner
	if kind == Lexer.T_OP and str(tok["v"]) == "[":
		_pos += 1
		var elems: Array = []
		if not _at_op("]"):
			while true:
				elems.append(_parse_expr())
				if _fail != "":
					return null
				if _at_op(","):
					_pos += 1
					if _at_op("]"):
						break
					continue
				break
		if not _expect_op("]"):
			return null
		return {"t": "list", "e": elems, "line": line}
	if kind == Lexer.T_OP and str(tok["v"]) == "{":
		_pos += 1
		var keys: Array = []
		var values: Array = []
		if not _at_op("}"):
			while true:
				keys.append(_parse_expr())
				if _fail != "":
					return null
				if not _expect_op(":"):
					return null
				values.append(_parse_expr())
				if _fail != "":
					return null
				if _at_op(","):
					_pos += 1
					if _at_op("}"):
						break
					continue
				break
		if not _expect_op("}"):
			return null
		return {"t": "dict", "k": keys, "v": values, "line": line}
	_set_error("第 %d 行：不认识的语法 '%s'" % [line, str(tok["v"])])
	return null


func _number_node(text: String, line: int) -> Dictionary:
	var clean := text
	if clean.begins_with("0x") or clean.begins_with("0X"):
		return {"t": "num", "v": clean.hex_to_int(), "line": line}
	if clean.find(".") >= 0 or clean.find("e") >= 0 or clean.find("E") >= 0:
		return {"t": "num", "v": float(clean), "line": line}
	return {"t": "num", "v": int(clean), "line": line}
