extends SceneTree
## 资源经济 / 掉落 / 生产建筑 的 headless 测试

const Economy = preload("res://scripts/economy/economy.gd")
const Production = preload("res://scripts/economy/production.gd")
const BlockDB = preload("res://scripts/world/block_db.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")

var _passed := 0
var _failed := 0


func _record(name: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)


func _initialize() -> void:
	var block_db := BlockDB.new()
	var problem := block_db.load_dir("res://data/blocks")
	_record("方块数据可加载", problem == "", problem)

	var unit_db := UnitDB.new()
	var uproblem := unit_db.load_dir("res://data/units")
	_record("单位数据可加载", uproblem == "", uproblem)

	# —— 基础账本 ——
	var econ := Economy.new()
	econ.setup(block_db, {"stone": 100})
	_record("初始资源正确", econ.amount("stone") == 100, str(econ.amount("stone")))
	_record("未拥有的资源数量为 0", econ.amount("copper") == 0, str(econ.amount("copper")))

	var signal_count := [0]
	econ.changed.connect(func(_resources: Dictionary): signal_count[0] += 1)
	econ.add("copper", 5)
	_record("add 后数量正确", econ.amount("copper") == 5, str(econ.amount("copper")))
	_record("add 发出 changed", signal_count[0] == 1, str(signal_count[0]))
	econ.add("copper", -3)
	_record("add 负数被忽略", econ.amount("copper") == 5, str(econ.amount("copper")))

	var snapshot := econ.all()
	snapshot["stone"] = 0
	snapshot["diamond"] = 999
	_record("all() 返回副本", econ.amount("stone") == 100 and econ.amount("diamond") == 0,
		"stone=%d diamond=%d" % [econ.amount("stone"), econ.amount("diamond")])

	# —— 支付 ——
	_record("can_afford 够付", econ.can_afford({"stone": 100, "copper": 5}))
	_record("can_afford 不够付", not econ.can_afford({"stone": 101}))
	var ok_spend := econ.spend({"stone": 40, "copper": 5})
	_record("spend 成功返回 true", ok_spend)
	_record("spend 正确扣除", econ.amount("stone") == 60 and econ.amount("copper") == 0,
		"stone=%d copper=%d" % [econ.amount("stone"), econ.amount("copper")])

	var dirty_count: int = signal_count[0]
	var ok_fail := econ.spend({"stone": 999, "copper": 1})
	_record("spend 失败返回 false", not ok_fail)
	_record("spend 失败不扣任何资源", econ.amount("stone") == 60 and econ.amount("copper") == 0,
		"stone=%d copper=%d" % [econ.amount("stone"), econ.amount("copper")])
	_record("spend 失败不发 changed", signal_count[0] == dirty_count, str(signal_count[0] - dirty_count))

	econ.refund({"stone": 10, "coal": 2})
	_record("refund 加回资源", econ.amount("stone") == 70 and econ.amount("coal") == 2,
		"stone=%d coal=%d" % [econ.amount("stone"), econ.amount("coal")])

	# —— 掉落 ——
	var coal_id := block_db.id_of("coal_ore")
	var grass_id := block_db.id_of("grass")
	_record("drop_of 煤矿 → coal", econ.drop_of(coal_id) == "coal", econ.drop_of(coal_id))
	_record("drop_of 草 → grass", econ.drop_of(grass_id) == "grass", econ.drop_of(grass_id))
	_record("drop_of 空气 → 空串", econ.drop_of(BlockDB.AIR) == "", econ.drop_of(BlockDB.AIR))

	var coal_before := econ.amount("coal")
	var mined := econ.mine_block(coal_id)
	_record("mine_block 掉落物名", mined == "coal", mined)
	_record("mine_block 挖煤矿得到 coal", econ.amount("coal") == coal_before + 1,
		"%d -> %d" % [coal_before, econ.amount("coal")])
	_record("mine_block 挖空气返回空串", econ.mine_block(BlockDB.AIR) == "")

	# —— 单位造价 ——
	var feifei := unit_db.get_def("feifei")
	_record("飞飞定义有 cost", not feifei.is_empty() and feifei.has("cost"))
	var cost := econ.unit_cost(feifei)
	_record("飞飞造价 = {copper:18, coal:8}",
		cost == {"copper": 18, "coal": 8}, str(cost))
	_record("unit_cost 缺省为空表", econ.unit_cost({}) == {})

	# —— 生产建筑 ——
	var prod := Production.new()
	var pecon := Economy.new()
	pecon.setup(block_db, {"coal": 3})
	prod.setup(pecon)
	prod.add_recipe("smelt", {"coal": 1}, {"copper": 2}, 1.0)
	prod.add_building("smelt")
	_record("生产建筑计数", prod.count_of("smelt") == 1, str(prod.count_of("smelt")))
	_record("recipe_ids 含注册配方", prod.recipe_ids().has("smelt"))

	_record("未满一秒不生产", prod.tick(0.5) == 0)
	_record("资源未变（还没到点）", pecon.amount("copper") == 0 and pecon.amount("coal") == 3,
		"coal=%d copper=%d" % [pecon.amount("coal"), pecon.amount("copper")])

	var done := prod.tick(0.5)
	_record("满一秒生产一次", done == 1, str(done))
	_record("生产扣输入", pecon.amount("coal") == 2, str(pecon.amount("coal")))
	_record("生产加输出", pecon.amount("copper") == 2, str(pecon.amount("copper")))

	var done2 := prod.tick(3.0)
	_record("大 delta 补算多轮", done2 == 2, str(done2))
	_record("两轮后资源正确", pecon.amount("coal") == 0 and pecon.amount("copper") == 6,
		"coal=%d copper=%d" % [pecon.amount("coal"), pecon.amount("copper")])

	var done3 := prod.tick(5.0)
	_record("输入不足不生产", done3 == 0, str(done3))
	_record("输入不足资源不变", pecon.amount("coal") == 0 and pecon.amount("copper") == 6,
		"coal=%d copper=%d" % [pecon.amount("coal"), pecon.amount("copper")])

	prod.add_building("smelt")
	_record("再加一座建筑", prod.count_of("smelt") == 2, str(prod.count_of("smelt")))
	prod.remove_building("smelt")
	_record("拆掉一座建筑", prod.count_of("smelt") == 1, str(prod.count_of("smelt")))

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
