extends RefCounted
## 字节码定义（编译器与虚拟机共用）

const CONST := 1
const LOAD := 2
const STORE := 3
const LOAD_ATTR := 4
const STORE_ATTR := 5
const GET_ITEM := 6
const SET_ITEM := 7
const CALL := 8
const BIN := 9
const UNARY := 10
const CMP := 11
const JUMP := 12
const JF := 13
const JT := 14
const DUP := 15
const POP := 16
const LINE := 17
const RETURN := 18
const HALT := 19
const FUNC := 20
const ITER := 21
const FOR_NEXT := 22
const BUILD_LIST := 23
const BUILD_DICT := 24
const AUG_ATTR := 25
const AUG_ITEM := 26
const UNPACK := 27
const NOP := 28

const NAMES := {
	1: "CONST", 2: "LOAD", 3: "STORE", 4: "LOAD_ATTR", 5: "STORE_ATTR",
	6: "GET_ITEM", 7: "SET_ITEM", 8: "CALL", 9: "BIN", 10: "UNARY",
	11: "CMP", 12: "JUMP", 13: "JF", 14: "JT", 15: "DUP", 16: "POP",
	17: "LINE", 18: "RETURN", 19: "HALT", 20: "FUNC", 21: "ITER",
	22: "FOR_NEXT", 23: "BUILD_LIST", 24: "BUILD_DICT", 25: "AUG_ATTR",
	26: "AUG_ITEM", 27: "UNPACK", 28: "NOP",
}


static func name_of(op: int) -> String:
	return str(NAMES.get(op, "?"))

## 运算符的整数编码：VM 加载字节码时把字符串运算符改写成这些整数，
## 运行时就不必对字符串做线性 match（字符串比较比整数慢很多）。
const BIN_ADD := 1
const BIN_SUB := 2
const BIN_MUL := 3
const BIN_DIV := 4
const BIN_FLOORDIV := 5
const BIN_MOD := 6
const BIN_POW := 7

const CMP_EQ := 1
const CMP_NE := 2
const CMP_LT := 3
const CMP_GT := 4
const CMP_LE := 5
const CMP_GE := 6
const CMP_IN := 7
const CMP_NOT_IN := 8

const UN_NOT := 1
const UN_NEG := 2
const UN_POS := 3
const UN_INVERT := 4

const BIN_OPS := {
	"+": BIN_ADD, "-": BIN_SUB, "*": BIN_MUL, "/": BIN_DIV,
	"//": BIN_FLOORDIV, "%": BIN_MOD, "**": BIN_POW,
}
const BIN_NAMES := {
	BIN_ADD: "+", BIN_SUB: "-", BIN_MUL: "*", BIN_DIV: "/",
	BIN_FLOORDIV: "//", BIN_MOD: "%", BIN_POW: "**",
}
const CMP_OPS := {
	"==": CMP_EQ, "!=": CMP_NE, "<": CMP_LT, ">": CMP_GT,
	"<=": CMP_LE, ">=": CMP_GE, "in": CMP_IN, "not in": CMP_NOT_IN,
}
const CMP_NAMES := {
	CMP_EQ: "==", CMP_NE: "!=", CMP_LT: "<", CMP_GT: ">",
	CMP_LE: "<=", CMP_GE: ">=", CMP_IN: "in", CMP_NOT_IN: "not in",
}
const UN_OPS := {"not": UN_NOT, "-": UN_NEG, "+": UN_POS, "~": UN_INVERT}
const UN_NAMES := {UN_NOT: "not", UN_NEG: "-", UN_POS: "+", UN_INVERT: "~"}

