extends Node

const RANGE := 0.5
const WATTS := 800.0


func _physics_process(delta: float) -> void:
	var pads: Array[Dictionary] = []
	for node in get_tree().get_nodes_in_group("charge_pad"):
		var info := _read(node)
		if info.is_empty():
			continue
		pads.append(info)
	var step_j := WATTS * delta
	for i in pads.size():
		for j in pads.size():
			if i == j:
				continue
			var source: Dictionary = pads[i]
			var sink: Dictionary = pads[j]
			if source["pool"] == sink["pool"]:
				continue
			if not bool(source["on"]) or not bool(sink["on"]):
				continue
			if str(source["mode"]) != "out" or str(sink["mode"]) != "in":
				continue
			var src_pos: Vector3 = source["pos"]
			var dst_pos: Vector3 = sink["pos"]
			if src_pos.distance_to(dst_pos) > RANGE:
				continue
			var have := float(source["energy"])
			var room := float(sink["cap"]) - float(sink["energy"])
			var move := minf(step_j, minf(have, room))
			if move <= 0.0:
				continue
			_add(source, -move)
			_add(sink, move)
			source["energy"] = have - move
			sink["energy"] = float(sink["energy"]) + move


func _read(node: Node) -> Dictionary:
	if not is_instance_valid(node):
		return {}
	if node.is_in_group("world_pad"):
		return {
			"pos": node.global_position,
			"on": bool(node.get("enabled")),
			"mode": str(node.get("mode")),
			"pool": node,
			"energy": float(node.get("energy_j")),
			"cap": float(node.get("energy_cap")),
		}
	if node is RigidBody3D and node.has_meta("pad_unit"):
		var unit: Node = node.get_meta("pad_unit")
		if not is_instance_valid(unit):
			return {}
		var index := int(node.get_meta("pad_index"))
		var flags: Array = unit.get("pad_on")
		var modes: Array = unit.get("pad_mode")
		if index < 0 or index >= flags.size() or index >= modes.size():
			return {}
		return {
			"pos": node.global_position,
			"on": bool(flags[index]),
			"mode": str(modes[index]),
			"pool": unit,
			"energy": float(unit.get("energy_j")),
			"cap": float(unit.get("energy_max")),
		}
	return {}


func _add(info: Dictionary, amount: float) -> void:
	var pool: Node = info["pool"]
	if not is_instance_valid(pool):
		return
	if pool.is_in_group("world_pad"):
		var cap := float(pool.get("energy_cap"))
		pool.set("energy_j", clampf(float(pool.get("energy_j")) + amount, 0.0, cap))
		return
	var cap_u := float(pool.get("energy_max"))
	pool.set("energy_j", clampf(float(pool.get("energy_j")) + amount, 0.0, cap_u))
