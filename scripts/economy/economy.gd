extends RefCounted
## 资源经济：记录各种资源的数量，负责采集掉落与花费结算。
## 只做纯逻辑，不依赖场景树；block_db 只用来查询方块的掉落物。

signal changed(resources: Dictionary)

var _block_db = null            ## 方块定义表（block_db.gd 实例）
var _amounts: Dictionary = {}   ## 资源名 -> 数量（整数）


func setup(block_db, starting: Dictionary = {}) -> void:
	## 记录方块表引用，清空资源并按 starting 初始化
	_block_db = block_db
	_amounts.clear()
	for kind in starting.keys():
		var key := str(kind)
		var count := int(starting[kind])
		_amounts[key] = maxi(count, 0)
	if not starting.is_empty():
		changed.emit(all())


func amount(kind: String) -> int:
	return int(_amounts.get(kind, 0))


func all() -> Dictionary:
	## 返回资源快照的副本，调用方随便改都不影响内部账本
	return _amounts.duplicate()


func add(kind: String, count: int) -> void:
	## 加资源；数量 <= 0 时直接忽略
	if kind == "" or count <= 0:
		return
	_amounts[kind] = amount(kind) + count
	changed.emit(all())


func can_afford(cost: Dictionary) -> bool:
	## 逐项检查是否够付，非正数的条目视为免费
	for kind in cost.keys():
		var need := int(cost[kind])
		if need > amount(str(kind)):
			return false
	return true


func spend(cost: Dictionary) -> bool:
	## 一次结算：不够就整体失败，一分不扣
	if not can_afford(cost):
		return false
	for kind in cost.keys():
		var need := int(cost[kind])
		if need <= 0:
			continue
		var key := str(kind)
		var left := amount(key) - need
		# 账本里保留 0，方便 all() 继续包含“曾经拥有过”的资源
		_amounts[key] = maxi(left, 0)
	changed.emit(all())
	return true


func refund(cost: Dictionary) -> void:
	## 退款：只有正数条目会加回去，最后统一发一次 changed
	var dirty := false
	for kind in cost.keys():
		var count := int(cost[kind])
		if count <= 0:
			continue
		var key := str(kind)
		_amounts[key] = amount(key) + count
		dirty = true
	if dirty:
		changed.emit(all())


func drop_of(block_id: int) -> String:
	## 方块被挖掉后掉什么：优先用 drop 字段，没写就掉方块自己
	if _block_db == null:
		return ""
	var def = _block_db.get_def(block_id)
	if def == null:
		return ""
	# 空气没有掉落物，单独判掉（它的 name 也是 "air"）
	if def.name == "air":
		return ""
	if def.drop != "":
		return def.drop
	return def.name


func mine_block(block_id: int, count: int = 1) -> String:
	## 挖掉 count 个方块，把掉落物入账，返回资源名（空气返回空串）
	var kind := drop_of(block_id)
	if kind == "" or count <= 0:
		return ""
	add(kind, count)
	return kind


func unit_cost(unit_def: Dictionary) -> Dictionary:
	## 单位定义里的造价表，缺省视为免费；JSON 数字是浮点，统一转成整数
	var cost = unit_def.get("cost", {})
	if not (cost is Dictionary):
		return {}
	var result: Dictionary = {}
	for kind in cost.keys():
		result[str(kind)] = int(cost[kind])
	return result
