extends Node3D
## 体素世界：按区块生成网格与碰撞，支持挖掘/放置。

const BlockDB = preload("res://scripts/world/block_db.gd")
const TerrainGen = preload("res://scripts/world/terrain_gen.gd")

const CHUNK := 16
const MAX_CHUNK_BUILDS_PER_FRAME := 3
const BUILD_BUDGET_USEC := 7000

class Chunk:
	extends Node3D
	var coord := Vector2i.ZERO
	var mesh_instance: MeshInstance3D
	var body: StaticBody3D
	var shape: ConcavePolygonShape3D
	var dirty := false
	var built := false

var db: BlockDB
var terrain: TerrainGen
var size_x := 192
var size_z := 192
var size_y := 72
var chunks := {}
var pending: Array[Vector2i] = []
var edits := {}

var _material: StandardMaterial3D
var _focus := Vector3.ZERO
var _view_chunks := 20
var _colors_top := PackedColorArray()
var _colors_side := PackedColorArray()
var edited_chunks := {}
var _bedrock_id := 7

## 分界线颜色（画在中立区两侧的断面面上）
const BOUNDARY_A_COLOR := Color(0.28, 0.45, 0.95)
const BOUNDARY_B_COLOR := Color(0.9, 0.22, 0.2)
const BOUNDARY_THICKNESS := 1
const CURTAIN_HEIGHT := 1.6
const CURTAIN_ALPHA := 1.0

## 每个方向的明暗系数（经典体素游戏的烘焙面光照）
const FACE_SHADE := [0.80, 0.80, 1.0, 0.50, 0.66, 0.66]

const FACE_DIRS := [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

## 每个方向一个四边形的 4 个角（单位立方体局部坐标）
const FACE_CORNERS := [
	[Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	[Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)],
	[Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)],
	[Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)],
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)],
]


func setup(block_db: BlockDB, world_seed: int, sx: int, sz: int, sy: int) -> void:
	db = block_db
	size_x = sx
	size_z = sz
	size_y = sy
	terrain = TerrainGen.new()
	terrain.setup(db, world_seed)
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.metallic = 0.0
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bedrock_id = db.id_of("bedrock")
	_build_boundary_curtains()
	_colors_top.resize(db.defs.size())
	_colors_side.resize(db.defs.size())
	for def in db.defs:
		_colors_top[def.id] = def.face_color(true)
		_colors_side[def.id] = def.face_color(false)


## 中立区两侧的分界：贴着地表起伏的一条发光色带
func _build_boundary_curtains() -> void:
	var holder := Node3D.new()
	holder.name = "Boundaries"
	add_child(holder)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	for spec in [[TerrainGen.ZONE_A_END, BOUNDARY_A_COLOR], [TerrainGen.ZONE_B_START, BOUNDARY_B_COLOR]]:
		var px: float = float(spec[0])
		var col: Color = spec[1]
		var verts := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		for z in size_z:
			var h := float(terrain.height_at(int(px), z)) + 1.0
			var z0 := float(z)
			var z1 := float(z + 1)
			var lin := col.srgb_to_linear()
			var i := verts.size()
			verts.append(Vector3(px, h, z0))
			verts.append(Vector3(px, h, z1))
			verts.append(Vector3(px, h + CURTAIN_HEIGHT, z1))
			verts.append(Vector3(px, h + CURTAIN_HEIGHT, z0))
			colors.append(Color(lin.r, lin.g, lin.b, CURTAIN_ALPHA))
			colors.append(Color(lin.r, lin.g, lin.b, CURTAIN_ALPHA))
			colors.append(Color(lin.r, lin.g, lin.b, 0.9))
			colors.append(Color(lin.r, lin.g, lin.b, 0.9))
			indices.append_array([i, i + 1, i + 2, i, i + 2, i + 3])
		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)


## 边界线下的一圈地表颜色（不在边上返回透明）
func _line_color_at(gx: int) -> Color:
	if gx == TerrainGen.ZONE_A_END - 1:
		return BOUNDARY_A_COLOR
	if gx == TerrainGen.ZONE_B_START:
		return BOUNDARY_B_COLOR
	return Color(0, 0, 0, 0)


func in_bounds(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.x < size_x and cell.z >= 0 and cell.z < size_z and cell.y >= 0 and cell.y < size_y


func get_block(cell: Vector3i) -> int:
	if cell.y < 0:
		return db.id_of("bedrock")
	if not in_bounds(cell):
		return BlockDB.AIR
	var override = edits.get(cell, null)
	if override != null:
		return override
	return terrain.base_block(cell.x, cell.y, cell.z)


func is_solid(cell: Vector3i) -> bool:
	return db.is_solid(get_block(cell))


func is_opaque(cell: Vector3i) -> bool:
	return db.is_opaque(get_block(cell))


func set_block(cell: Vector3i, block_id: int) -> void:
	if not in_bounds(cell):
		return
	var base := terrain.base_block(cell.x, cell.y, cell.z)
	if base == block_id:
		edits.erase(cell)
	else:
		edits[cell] = block_id
	var c := chunk_of(cell)
	edited_chunks[c] = true
	_mark_dirty(c)
	if cell.x % CHUNK == 0:
		_mark_dirty(c + Vector2i(-1, 0))
	if (cell.x + 1) % CHUNK == 0:
		_mark_dirty(c + Vector2i(1, 0))
	if cell.z % CHUNK == 0:
		_mark_dirty(c + Vector2i(0, -1))
	if (cell.z + 1) % CHUNK == 0:
		_mark_dirty(c + Vector2i(0, 1))


func chunk_of(cell: Vector3i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / float(CHUNK)), floori(float(cell.z) / float(CHUNK)))


func chunk_count_x() -> int:
	return ceili(float(size_x) / float(CHUNK))


func chunk_count_z() -> int:
	return ceili(float(size_z) / float(CHUNK))


## 每帧按距离补建区块
func update_streaming(focus: Vector3) -> void:
	_focus = focus
	var fc := Vector2i(floori(focus.x / float(CHUNK)), floori(focus.z / float(CHUNK)))
	var wanted := {}
	for dz in range(-_view_chunks, _view_chunks + 1):
		for dx in range(-_view_chunks, _view_chunks + 1):
			var c := fc + Vector2i(dx, dz)
			if c.x < 0 or c.y < 0 or c.x >= chunk_count_x() or c.y >= chunk_count_z():
				continue
			wanted[c] = true
			if not chunks.has(c):
				if not pending.has(c):
					pending.append(c)
			elif chunks[c].dirty:
				_rebuild(chunks[c])
	# 卸载视野外区块
	for key in chunks.keys():
		if not wanted.has(key):
			var chunk: Chunk = chunks[key]
			chunks.erase(key)
			chunk.queue_free()
	# 由近到远排队
	pending.sort_custom(func(a: Vector2i, b: Vector2i):
		return Vector2(a - fc).length_squared() < Vector2(b - fc).length_squared())
	var budget := MAX_CHUNK_BUILDS_PER_FRAME
	var deadline := Time.get_ticks_usec() + BUILD_BUDGET_USEC
	while budget > 0 and not pending.is_empty():
		var c: Vector2i = pending.pop_front()
		if not chunks.has(c):
			_build(c)
		budget -= 1
		if Time.get_ticks_usec() >= deadline:
			break


## 快速预建以 center 为中心、半径 radius 个区块的范围（启动时用）
func prefetch(center: Vector3, radius: int) -> void:
	var fc := Vector2i(floori(center.x / float(CHUNK)), floori(center.z / float(CHUNK)))
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var c := fc + Vector2i(dx, dz)
			if c.x < 0 or c.y < 0 or c.x >= chunk_count_x() or c.y >= chunk_count_z():
				continue
			if not chunks.has(c):
				_build(c)


## 同步构建所有区块（测试/小地图用）
func build_all() -> void:
	for cz in chunk_count_z():
		for cx in chunk_count_x():
			_build(Vector2i(cx, cz))


func surface_height(x: int, z: int) -> int:
	var top := size_y - 1
	for y in range(size_y - 1, -1, -1):
		if db.is_solid(get_block(Vector3i(x, y, z))):
			top = y
			break
	return top + 1


func _mark_dirty(coord: Vector2i) -> void:
	if coord.x < 0 or coord.y < 0 or coord.x >= chunk_count_x() or coord.y >= chunk_count_z():
		return
	var chunk: Chunk = chunks.get(coord, null)
	if chunk == null:
		return
	edited_chunks[coord] = true
	chunk.dirty = true
	_rebuild(chunk)


func _build(coord: Vector2i) -> void:
	var chunk := Chunk.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]
	chunk.coord = coord
	add_child(chunk)
	chunk.mesh_instance = MeshInstance3D.new()
	chunk.body = StaticBody3D.new()
	chunk.body.collision_layer = 1
	chunk.body.collision_mask = 0
	var col := CollisionShape3D.new()
	chunk.shape = ConcavePolygonShape3D.new()
	col.shape = chunk.shape
	chunk.body.add_child(col)
	chunk.add_child(chunk.mesh_instance)
	chunk.add_child(chunk.body)
	chunks[coord] = chunk
	_rebuild(chunk)


func _rebuild(chunk: Chunk) -> void:
	chunk.dirty = false
	var x0 := chunk.coord.x * CHUNK
	var z0 := chunk.coord.y * CHUNK
	var w := CHUNK + 2
	var w2 := w * w
	var heights := PackedInt32Array()
	heights.resize(w2)
	var max_h := 0
	var min_h := size_y - 1
	for lz in w:
		var gz := z0 + lz - 1
		for lx in w:
			var gx := x0 + lx - 1
			var h := -1
			if gx >= 0 and gx < size_x and gz >= 0 and gz < size_z:
				h = clampi(terrain.height_at(gx, gz), 0, size_y - 1)
			heights[lz * w + lx] = h
			if h > max_h:
				max_h = h
			if h >= 0 and h < min_h:
				min_h = h
	var has_edits: bool = edited_chunks.has(chunk.coord)
	var local_edits: Array = []
	var edit_top := -1
	var edit_bottom := size_y
	if has_edits:
		for key in edits.keys():
			var cell: Vector3i = key
			var lx2 := cell.x - x0 + 1
			var lz2 := cell.z - z0 + 1
			if lx2 < 0 or lx2 >= w or lz2 < 0 or lz2 >= w:
				continue
			local_edits.append([lx2, cell.y, lz2, edits[key]])
			if cell.y > edit_top:
				edit_top = cell.y
			if cell.y < edit_bottom:
				edit_bottom = cell.y
	var lo := maxi(0, min_h - 1)
	var hi := maxi(max_h + 1, 0)
	if has_edits and edit_top >= 0:
		hi = mini(size_y - 1, maxi(hi, edit_top + 1))
		lo = maxi(0, mini(lo, edit_bottom - 1))
	var y_count := hi - lo + 1
	var buf := PackedByteArray()
	buf.resize(w2 * y_count)
	# 填充方块缓冲区（地形）
	for lz in w:
		var gz := z0 + lz - 1
		if gz < 0 or gz >= size_z:
			continue
		for lx in w:
			var gx := x0 + lx - 1
			if gx < 0 or gx >= size_x:
				continue
			var h: int = heights[lz * w + lx]
			if h < 0:
				continue
			var top := mini(h, hi)
			for y in range(maxi(0, lo), top + 1):
				buf[(y - lo) * w2 + lz * w + lx] = terrain.block_at_height(gx, y, gz, h)
	# 应用玩家改动
	for entry in local_edits:
		var ey: int = entry[1]
		if ey < lo or ey > hi:
			continue
		buf[(ey - lo) * w2 + int(entry[2]) * w + int(entry[0])] = entry[3]

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	for lx in CHUNK:
		var gx := x0 + lx
		if gx >= size_x:
			break
		for lz in CHUNK:
			var gz := z0 + lz
			if gz >= size_z:
				break
			for y in range(lo, hi + 1):
				var base := (y - lo) * w2 + (lz + 1) * w + (lx + 1)
				var block_id: int = buf[base]
				if block_id == BlockDB.AIR or not db.is_solid(block_id):
					continue
				var cell_pos := Vector3(gx, y, gz)
				for f in 6:
					var dir: Vector3i = FACE_DIRS[f]
					var ny := y + dir.y
					var nb: int
					if ny < lo:
						nb = _bedrock_id
					elif ny > hi:
						nb = BlockDB.AIR
					else:
						nb = buf[base + dir.y * w2 + dir.z * w + dir.x]
					if nb != BlockDB.AIR and db.is_opaque(nb):
						continue
					var color: Color = _colors_top[block_id] if dir.y > 0 else _colors_side[block_id]
					if dir.x != 0:
						var plane_x := gx + 1 if dir.x > 0 else gx
						if plane_x == TerrainGen.ZONE_A_END:
							color = BOUNDARY_A_COLOR
						elif plane_x == TerrainGen.ZONE_B_START:
							color = BOUNDARY_B_COLOR
					else:
						# 边界线上的一圈地表染成队色
						var line_color = _line_color_at(gx)
						if line_color.a > 0.0:
							color = line_color
					color = color.srgb_to_linear() * float(FACE_SHADE[f])
					var base_index := verts.size()
					var corners: Array = FACE_CORNERS[f]
					for corner in corners:
						verts.append(cell_pos + corner)
						normals.append(Vector3(dir))
						colors.append(color)
					indices.append(base_index)
					indices.append(base_index + 1)
					indices.append(base_index + 2)
					indices.append(base_index)
					indices.append(base_index + 2)
					indices.append(base_index + 3)
					faces.append(verts[base_index])
					faces.append(verts[base_index + 1])
					faces.append(verts[base_index + 2])
					faces.append(verts[base_index])
					faces.append(verts[base_index + 2])
					faces.append(verts[base_index + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _material)
	chunk.mesh_instance.mesh = mesh
	chunk.shape.set_faces(faces)
	chunk.built = true


## 该格是否允许玩家建造/破坏（中立区禁止）
func is_buildable(cell: Vector3i) -> bool:
	return not terrain.is_neutral(cell.x)


## 射线检测：返回 {cell, normal, point}，未命中返回空字典
func raycast(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var cell := Vector3i(
		floori(point.x - normal.x * 0.5),
		floori(point.y - normal.y * 0.5),
		floori(point.z - normal.z * 0.5))
	return {"cell": cell, "normal": Vector3i(normal.round()), "point": point}
