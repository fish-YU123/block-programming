extends RefCounted
## 单位代码词法分析器：Python 子集 -> token 流。
## 缩进敏感（空格；Tab 按 4 空格展开），支持中文标识符与中文注释，
## 括号内换行不算语句结束，反斜杠可续行。

const T_NAME := 1
const T_NUM := 2
const T_STR := 3
const T_OP := 4
const T_NEWLINE := 5
const T_INDENT := 6
const T_DEDENT := 7
const T_EOF := 8

const KEYWORDS := [
	"if", "elif", "else", "while", "for", "in", "and", "or", "not",
	"def", "return", "break", "continue", "pass",
	"True", "False", "None",
]

## 明确不支持、给出友好提示的 Python 语法
const UNSUPPORTED := {
	"import": "不支持 import，请直接使用内置函数",
	"from": "不支持 import",
	"class": "不支持 class，请用函数和 mem 字典",
	"lambda": "不支持 lambda，请定义一个函数",
	"try": "不支持 try/except",
	"except": "不支持 try/except",
	"finally": "不支持 try/except",
	"global": "不支持 global",
	"nonlocal": "不支持 nonlocal",
	"with": "不支持 with",
	"assert": "不支持 assert",
	"yield": "不支持 yield",
	"raise": "不支持 raise",
	"async": "不支持 async",
	"await": "不支持 await",
	"is": "不支持 is，请用 ==",
}

const OPS := [
	"**=", "//=", ">>=", "<<=",
	"==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "**", "//", "<<", ">>", "->",
	"(", ")", "[", "]", "{", "}", ",", ":", ".", ";",
	"+", "-", "*", "/", "%", "<", ">", "=", "&", "|", "^", "~", "@",
]

var _src := ""
var _n := 0
var _i := 0
var _line := 1
var _toks: Array = []
var _indents: Array = [0]
var _bracket := 0


func tokenize(src: String) -> Dictionary:
	_src = src.replace("\r\n", "\n").replace("\r", "\n")
	_n = _src.length()
	_i = 0
	_line = 1
	_toks = []
	_indents = [0]
	_bracket = 0
	while true:
		if _i >= _n:
			break
		var c := _src.unicode_at(_i)
		if c == 10:
			_line += 1
			_i += 1
			if _bracket > 0:
				continue
			_emit_newline()
			var res := _read_indent()
			if res != "":
				return _err(res)
			if _i >= _n:
				break
			continue
		if c == 32 or c == 9:
			_i += 1
			continue
		if c == 35:
			while _i < _n and _src.unicode_at(_i) != 10:
				_i += 1
			continue
		if c == 92:
			var nxt := _cmp(1)
			if nxt == 10:
				_i += 2
				_line += 1
				continue
			return _err("第 %d 行：反斜杠后面必须换行" % _line)
		if _is_quote(c):
			var text := _read_string()
			if _i < 0:
				return _err(_fail)
			_push(T_STR, text)
			continue
		if _is_digit(c) or (c == 46 and _is_digit(_cmp(1))):
			var num := _read_number()
			if _i < 0:
				return _err(_fail)
			_push(T_NUM, num)
			continue
		if _is_ident_start(c):
			var name := _read_name()
			if _i < 0:
				return _err(_fail)
			_push(T_NAME, name)
			continue
		var op := _read_op()
		if op == "":
			return _err("第 %d 行：无法识别的字符 '%s'" % [_line, char(c)])
		_push(T_OP, op)
		if op == "(" or op == "[" or op == "{":
			_bracket += 1
		elif op == ")" or op == "]" or op == "}":
			_bracket = maxi(0, _bracket - 1)
	# 收尾
	_emit_newline()
	while _indents.size() > 1:
		_indents.pop_back()
		_toks.append({"t": T_DEDENT, "v": "", "line": _line})
	_toks.append({"t": T_EOF, "v": "", "line": _line})
	return {"ok": true, "tokens": _toks}


var _fail := ""


## 读到行首缩进并产生 INDENT/DEDENT；遇到空行/纯注释行则继续往后找
func _read_indent() -> String:
	while true:
		var width := 0
		while _i < _n:
			var c := _src.unicode_at(_i)
			if c == 32:
				width += 1
				_i += 1
			elif c == 9:
				width += 4
				_i += 1
			else:
				break
		if _i >= _n:
			return ""
		var c2 := _src.unicode_at(_i)
		if c2 == 10:
			_line += 1
			_i += 1
			continue
		if c2 == 35:
			while _i < _n and _src.unicode_at(_i) != 10:
				_i += 1
			continue
		var top: int = int(_indents[_indents.size() - 1])
		if width > top:
			_indents.append(width)
			_toks.append({"t": T_INDENT, "v": width, "line": _line})
		else:
			while width < int(_indents[_indents.size() - 1]):
				_indents.pop_back()
				_toks.append({"t": T_DEDENT, "v": "", "line": _line})
			if width != int(_indents[_indents.size() - 1]):
				return "第 %d 行：缩进不一致（缩进里不能混用空格和 Tab）" % _line
		return ""
	return ""


func _emit_newline() -> void:
	if _toks.is_empty():
		return
	var last: Dictionary = _toks[_toks.size() - 1]
	if int(last["t"]) == T_NEWLINE or int(last["t"]) == T_INDENT or int(last["t"]) == T_DEDENT:
		return
	_toks.append({"t": T_NEWLINE, "v": "", "line": _line})


func _push(kind: int, value) -> void:
	_toks.append({"t": kind, "v": value, "line": _line})


func _cmp(offset: int) -> int:
	var p := _i + offset
	if p < 0 or p >= _n:
		return -1
	return _src.unicode_at(p)


func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57


func _is_quote(c: int) -> bool:
	return c == 34 or c == 39


func _is_ident_start(c: int) -> bool:
	if c < 0:
		return false
	if c == 95:
		return true
	if c >= 65 and c <= 90:
		return true
	if c >= 97 and c <= 122:
		return true
	return c >= 128


func _is_ident_char(c: int) -> bool:
	if _is_ident_start(c):
		return true
	return _is_digit(c)


func _read_name() -> String:
	var start := _i
	while _i < _n and _is_ident_char(_src.unicode_at(_i)):
		_i += 1
	var name := _src.substr(start, _i - start)
	if name.length() >= 2 and (name.substr(0, 1) == "f" or name.substr(0, 1) == "F") and _is_quote(_cmp(0)):
		# f-string：不支持
		_fail = "第 %d 行：不支持 f-string，请用 str() 拼接" % _line
		_i = -1
		return ""
	if name.length() >= 2 and (name.substr(0, 1) == "r" or name.substr(0, 1) == "R") and _is_quote(_cmp(0)):
		_fail = "第 %d 行：不支持原始字符串 r''" % _line
		_i = -1
		return ""
	return name


func _read_number() -> String:
	var start := _i
	if _cmp(0) == 48 and (_cmp(1) == 120 or _cmp(1) == 88):
		_i += 2
		while _i < _n:
			var c := _src.unicode_at(_i)
			if _is_digit(c) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70) or c == 95:
				_i += 1
			else:
				break
		return _src.substr(start, _i - start)
	while _i < _n:
		var c := _src.unicode_at(_i)
		if _is_digit(c) or c == 95:
			_i += 1
		else:
			break
	if _cmp(0) == 46:
		_i += 1
		while _i < _n and (_is_digit(_src.unicode_at(_i)) or _src.unicode_at(_i) == 95):
			_i += 1
	if _cmp(0) == 101 or _cmp(0) == 69:
		var save := _i
		var q := _i + 1
		if q < _n and (_src.unicode_at(q) == 43 or _src.unicode_at(q) == 45):
			q += 1
		if q < _n and _is_digit(_src.unicode_at(q)):
			_i = q
			while _i < _n and _is_digit(_src.unicode_at(_i)):
				_i += 1
		else:
			_i = save
	var text := _src.substr(start, _i - start).replace("_", "")
	if text.find(".") >= 0 or text.find("e") >= 0 or text.find("E") >= 0:
		return text
	return text


func _read_string() -> String:
	var quote := _src.unicode_at(_i)
	if _cmp(1) == quote and _cmp(2) == quote:
		_fail = "第 %d 行：不支持三引号字符串" % _line
		_i = -1
		return ""
	_i += 1
	var out := ""
	while true:
		if _i >= _n:
			_fail = "第 %d 行：字符串没有结束" % _line
			_i = -1
			return ""
		var c := _src.unicode_at(_i)
		if c == 10:
			_fail = "第 %d 行：字符串里不能直接换行" % _line
			_i = -1
			return ""
		if c == quote:
			_i += 1
			return out
		if c == 92:
			_i += 1
			if _i >= _n:
				_fail = "第 %d 行：字符串没有结束" % _line
				_i = -1
				return ""
			var e := _src.unicode_at(_i)
			_i += 1
			if e == 110:
				out += "\n"
			elif e == 116:
				out += "\t"
			elif e == 114:
				out += "\r"
			elif e == 92:
				out += "\\"
			elif e == 39:
				out += "'"
			elif e == 34:
				out += "\""
			elif e == 48:
				out += "\u0000"
			elif e == 117:
				var hex := _src.substr(_i, 4)
				_i += 4
				out += char(hex.hex_to_int())
			elif e == 120:
				var hex2 := _src.substr(_i, 2)
				_i += 2
				out += char(hex2.hex_to_int())
			else:
				out += char(e)
			continue
		out += char(c)
		_i += 1
	return out


func _read_op() -> String:
	for op in OPS:
		var text: String = op
		if _src.length() - _i >= text.length() and _src.substr(_i, text.length()) == text:
			_i += text.length()
			return text
	return ""


func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message}
