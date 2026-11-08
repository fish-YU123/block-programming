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
