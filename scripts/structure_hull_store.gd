extends RefCounted

const PATH := "res://data/structure_hulls.json"
const Hull3D = preload("res://scripts/convex_hull_3d.gd")

# mask(string) -> Array of [x,y,z] int 0..2
var hulls := {}
# 64 种邻接 → 预先算好的格内三角（局部 [0,0.5]^3）
var tris_cache: Array = []
# 真正的「非方块」自定义形状（整盒/默认不算）
var _custom_masks := {}


func load_all() -> void:
	hulls.clear()
	if not FileAccess.file_exists(PATH):
		return
	var text := FileAccess.get_file_as_string(PATH)
	var data = JSON.parse_string(text)
	if data is Dictionary:
		hulls = data


func save_all() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("无法写入 %s" % PATH)
		return
	f.store_string(JSON.stringify(hulls, "\t"))


func get_points(mask: int) -> Array:
	var key := str(mask)
	if not hulls.has(key):
		return []
	var raw = hulls[key]
	if raw is Array:
		return raw
	return []


func set_points(mask: int, points: Array) -> void:
	hulls[str(mask)] = points


func has_hull(mask: int) -> bool:
	return get_points(mask).size() >= 3


func has_custom_shape(mask: int) -> bool:
	# 地形只用「精确保存」的非整盒形状，避免旋转展开把悬崖边也换成凸包导致缝
	var raw: Array = get_points(mask & 63)
	if raw.size() < 3:
		return false
	var pts := PackedVector3Array()
	for item in raw:
		if item is Array and item.size() >= 3:
			pts.append(point_index_to_local(Vector3(float(item[0]), float(item[1]), float(item[2]))))
	if pts.size() < 3:
		return false
	return not _is_full_cell_corners(pts)


func has_hull_cached(mask: int) -> bool:
	return _custom_masks.has(mask & 63) or has_custom_shape(mask)


func get_cached_tris(mask: int) -> PackedVector3Array:
	var m := mask & 63
	if m < 0 or m >= tris_cache.size():
		return PackedVector3Array()
	return tris_cache[m]


func point_index_to_local(p: Vector3) -> Vector3:
	return Vector3(p.x, p.y, p.z) * 0.25


func rebuild_tris_cache(_struct_pos: Array, rot_count: int, rotate_mask: Callable, rotate_cell: Callable) -> void:
	tris_cache.clear()
	tris_cache.resize(64)
	_custom_masks.clear()
	var cube := _unit_cube_tris()
	for mask in 64:
		tris_cache[mask] = cube
	for key in hulls.keys():
		var base := int(key)
		var saved: Array = get_points(base)
		if saved.size() < 3:
			continue
		for rot in rot_count:
			var rm: int = int(rotate_mask.call(base, rot)) & 63
			var pts := PackedVector3Array()
			for item in saved:
				if not (item is Array) or item.size() < 3:
					continue
				var cell: Vector3i = rotate_cell.call(Vector3i(int(item[0]), int(item[1]), int(item[2])), rot)
				pts.append(point_index_to_local(Vector3(cell.x, cell.y, cell.z)))
			if pts.size() < 3:
				continue
			if _is_full_cell_corners(pts):
				# 整格八点 = 普通方块，用地形高度场，不当地形自定义凸包
				tris_cache[rm] = cube
				_custom_masks.erase(rm)
				continue
			var tris: PackedVector3Array = Hull3D.build(pts)
			if tris.size() < 3:
				continue
			tris_cache[rm] = tris
			_custom_masks[rm] = true


func _is_full_cell_corners(pts: PackedVector3Array) -> bool:
	var need := {}
	for y in 2:
		for z in 2:
			for x in 2:
				need["%d,%d,%d" % [x, y, z]] = false
	var hit := 0
	for p in pts:
		var x := roundi(p.x * 2.0)
		var y := roundi(p.y * 2.0)
		var z := roundi(p.z * 2.0)
		if x < 0 or x > 1 or y < 0 or y > 1 or z < 0 or z > 1:
			continue
		var k := "%d,%d,%d" % [x, y, z]
		if need.has(k) and not need[k]:
			need[k] = true
			hit += 1
	return hit >= 8


func _unit_cube_tris() -> PackedVector3Array:
	var s := 0.5
	var p := [
		Vector3(0, 0, 0), Vector3(s, 0, 0), Vector3(s, s, 0), Vector3(0, s, 0),
		Vector3(0, 0, s), Vector3(s, 0, s), Vector3(s, s, s), Vector3(0, s, s),
	]
	var faces := [
		[0, 2, 1, 0, 3, 2], [4, 5, 6, 4, 6, 7], [0, 1, 5, 0, 5, 4],
		[3, 7, 6, 3, 6, 2], [0, 4, 7, 0, 7, 3], [1, 2, 6, 1, 6, 5],
	]
	var out := PackedVector3Array()
	for face in faces:
		for i in 6:
			out.append(p[face[i]])
	return out
