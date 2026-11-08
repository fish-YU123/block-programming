extends RefCounted
## 极简生产建筑：按配方周期性地把输入资源转成输出资源。
## 资源数量只用整数；计时用浮点秒。

var _economy = null
var _recipes: Dictionary = {}    ## 配方 id -> {"inputs": Dictionary, "outputs": Dictionary, "seconds": float}
var _buildings: Array = []       ## 每个建筑一项：{"id": String, "t": float}


func setup(economy) -> void:
	## 绑定经济账本，清空配方和建筑
	_economy = economy
	_recipes.clear()
	_buildings.clear()


func add_recipe(id: String, inputs: Dictionary, outputs: Dictionary, seconds: float) -> void:
	## 注册配方；seconds 至少 0.001 秒，避免除零/无限循环
	if id == "":
		return
	_recipes[id] = {
		"inputs": inputs.duplicate(),
		"outputs": outputs.duplicate(),
		"seconds": maxf(seconds, 0.001),
	}


func count_of(id: String) -> int:
	var total := 0
	for b in _buildings:
		if b["id"] == id:
			total += 1
	return total


func add_building(id: String) -> void:
	## 只有注册过的配方才能盖建筑
	if not _recipes.has(id):
		return
	_buildings.append({"id": id, "t": 0.0})


func remove_building(id: String) -> void:
	## 拆掉一座该配方的建筑（从后往前找第一个）
	for i in range(_buildings.size() - 1, -1, -1):
		if _buildings[i]["id"] == id:
			_buildings.remove_at(i)
			return


func tick(delta: float) -> int:
	## 推进所有建筑，返回本次完成的生产次数总和
	if _economy == null or delta <= 0.0:
		return 0
	var done := 0
	for b in _buildings:
		var recipe: Dictionary = _recipes.get(b["id"], {})
		if recipe.is_empty():
			continue
		var seconds: float = recipe["seconds"]
		b["t"] = float(b["t"]) + delta
		# 一个 tick 里可能攒够多轮生产（delta 很大时）
		while b["t"] >= seconds:
			if not _economy.spend(recipe["inputs"]):
				# 输入不够：停在“刚好攒满一轮”，等资源到位立刻开工
				b["t"] = seconds
				break
			for kind in recipe["outputs"].keys():
				_economy.add(str(kind), int(recipe["outputs"][kind]))
			b["t"] = float(b["t"]) - seconds
			done += 1
	return done


func recipe_ids() -> Array:
	return _recipes.keys()
