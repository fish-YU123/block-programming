extends Node3D
## 体素世界：按区块生成网格与碰撞，支持挖掘/放置。

const BlockDB = preload("res://scripts/world/block_db.gd")
const TerrainGen = preload("res://scripts/world/terrain_gen.gd")
const TextureAtlas = preload("res://scripts/world/texture_atlas.gd")

const CHUNK := 16
const MAX_CHUNK_BUILDS_PER_FRAME := 1
const BUILD_BUDGET_USEC := 8000

class Chunk:
	extends Node3D
	var coord := Vector2i.ZERO
	var mesh_instance: MeshInstance3D
	var body: StaticBody3D
	var shape: ConcavePolygonShape3D
	var col: CollisionShape3D
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
var atlas: TextureAtlas
var _focus := Vector3.ZERO
var _view_chunks := 20
## 每个方块顶/底/侧面的图集 UV 矩形（setup 时按方块 id 缓存）
var _uv_top: Array[Rect2] = []
var _uv_bottom: Array[Rect2] = []
var _uv_side: Array[Rect2] = []
## AO 邻居偏移缓存：_ao_offsets[面][角] = 3 个邻居的 buffer 字节偏移
var _ao_offsets: Array = []
## 同上的 y 偏移，用来判断是否越出当前区块的 y 范围
var _ao_dys: Array = []
## 方块 id -> 是否实心（AO 采样用，避免每像素查字典）
var _solid_ids := PackedByteArray()
var _opaque_ids := PackedByteArray()
## 性能用：把面表/AO 表摊平成 Packed 数组，建网格时不再做数组套数组的查表
var _face_corners: Array = []
var _face_uv_corners: Array = []
var _face_normals := PackedVector3Array()
var _ao_flat_offsets: Array = []
var _ao_flat_dys: Array = []
## 预计算的顶点色：下标 = 面 * 4 + AO 等级（避免每帧 new Color）
var _shade_colors := PackedColorArray()
var edited_chunks := {}
var _bedrock_id := 7
var _line_nodes := [null, null]
var _line_dirty := [false, false]

## 分界线颜色（贴地的一条细线，方块变动后自动重铺）
const BOUNDARY_A_COLOR := Color(0.28, 0.45, 0.95)
const BOUNDARY_B_COLOR := Color(0.9, 0.22, 0.2)
const LINE_HALF_WIDTH := 0.08
const LINE_LIFT := 0.02
const LINE_HEIGHT := 0.55
const LINE_ALPHA := 0.55

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

## 每个面的 4 个角在贴图里的 UV（0..1，y 向下），保证从外侧看图案是正的
const FACE_UV_CORNERS := [
	[Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)],
	[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
	[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
	[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
	[Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)],
	[Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)],
]

## 每个面除法线外的两条切线轴（0=x, 1=y, 2=z），用来找 AO 邻居
const FACE_TANGENTS := [
	[1, 2], [1, 2], [0, 2], [0, 2], [0, 1], [0, 1],
]

## 每个面的 4 个角在两条切线轴上的方向（-1 或 +1）
const FACE_AO_SIGNS := [
	[[-1, -1], [-1, 1], [1, 1], [1, -1]],
	[[-1, 1], [-1, -1], [1, -1], [1, 1]],
	[[-1, -1], [1, -1], [1, 1], [-1, 1]],
	[[-1, 1], [1, 1], [1, -1], [-1, -1]],
	[[1, -1], [-1, -1], [-1, 1], [1, 1]],
	[[-1, -1], [1, -1], [1, 1], [-1, 1]],
]

## 顶点 AO 的 4 级明暗：下标 = 遮挡的邻居数（0 个最亮，3 个最暗）
const AO_LEVELS := [1.0, 0.87, 0.74, 0.62]


func setup(block_db: BlockDB, world_seed: int, sx: int, sz: int, sy: int) -> void:
	db = block_db
	size_x = sx
	size_z = sz
	size_y = sy
	terrain = TerrainGen.new()
	terrain.setup(db, world_seed)
	# 程序生成的像素贴图：所有像素都在运行时画出来，不依赖外部图片素材
	atlas = TextureAtlas.new()
	atlas.build(db)
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.albedo_texture = atlas.texture
	# 像素风：最近邻采样 + 不重复（UV 都落在图集内部的格子里）
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_material.texture_repeat = false
	_material.roughness = 1.0
	_material.metallic = 0.0
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bedrock_id = db.id_of("bedrock")
	_build_ao_tables()
	_solid_ids.resize(256)
	_opaque_ids.resize(256)
	for def in db.defs:
		if def.id < 0 or def.id >= 256:
			continue
		if def.solid:
			_solid_ids[def.id] = 1
		if def.opaque:
			_opaque_ids[def.id] = 1
	_build_flat_tables()
	# 每种方块顶/底/侧面的 UV 只查一次图集，生成网格时直接按 id 取
	_uv_top.resize(db.defs.size())
	_uv_bottom.resize(db.defs.size())
	_uv_side.resize(db.defs.size())
	for def in db.defs:
		if def.id < 0 or def.id >= db.defs.size():
			continue
		_uv_top[def.id] = atlas.uv_rect(def.id, TextureAtlas.FACE_TOP)
		_uv_bottom[def.id] = atlas.uv_rect(def.id, TextureAtlas.FACE_BOTTOM)
		_uv_side[def.id] = atlas.uv_rect(def.id, TextureAtlas.FACE_SIDE)
	_build_boundaries()


## 把面角点/UV/法线摊平成 Packed 数组，并按「面 × AO 等级」预计算顶点色
func _build_flat_tables() -> void:
	_face_corners.clear()
	_face_uv_corners.clear()
	_face_normals.resize(6)
	_shade_colors.resize(24)
	for f in 6:
		_face_corners.append(PackedVector3Array(FACE_CORNERS[f]))
		_face_uv_corners.append(PackedVector2Array(FACE_UV_CORNERS[f]))
		_face_normals[f] = Vector3(FACE_DIRS[f])
		for level in 4:
			var shade := float(FACE_SHADE[f]) * float(AO_LEVELS[level])
			_shade_colors[f * 4 + level] = Color(shade, shade, shade)


## 预计算每个面 4 个角的 AO 邻居偏移（单位：格，换算成 buffer 字节偏移）
## 每个角看 3 个邻居：两个侧邻居 + 一个对角邻居，经典体素 AO。
func _build_ao_tables() -> void:
	var w := CHUNK + 2
	var w2 := w * w
	_ao_offsets.resize(6)
	_ao_dys.resize(6)
	_ao_flat_offsets.resize(6)
	_ao_flat_dys.resize(6)
	for f in 6:
		var dir: Vector3i = FACE_DIRS[f]
		var axis_a: int = FACE_TANGENTS[f][0]
		var axis_b: int = FACE_TANGENTS[f][1]
		var face_offsets := []
		var face_dys := []
		for k in 4:
			var signs: Array = FACE_AO_SIGNS[f][k]
			var ta := _axis_unit(axis_a, signs[0])
			var tb := _axis_unit(axis_b, signs[1])
			var neighbors := [dir + ta, dir + tb, dir + ta + tb]
			var deltas := PackedInt32Array()
			var dys := PackedInt32Array()
			for o: Vector3i in neighbors:
				deltas.append(o.y * w2 + o.z * w + o.x)
				dys.append(o.y)
			face_offsets.append(deltas)
			face_dys.append(dys)
		_ao_offsets[f] = face_offsets
		_ao_dys[f] = face_dys
		var flat_offsets := PackedInt32Array()
		var flat_dys := PackedInt32Array()
		for k in 4:
			var deltas: PackedInt32Array = face_offsets[k]
			var dys: PackedInt32Array = face_dys[k]
			for j in 3:
				flat_offsets.append(deltas[j])
				flat_dys.append(dys[j])
		_ao_flat_offsets[f] = flat_offsets
		_ao_flat_dys[f] = flat_dys


func _axis_unit(axis: int, sign: int) -> Vector3i:
	match axis:
		0:
			return Vector3i(sign, 0, 0)
		1:
			return Vector3i(0, sign, 0)
		_:
			return Vector3i(0, 0, sign)


## 中立区两侧的分界：贴地的一条细线（俯视见线，平视见竖条），改方块后自动重铺
func _build_boundaries() -> void:
	var holder := Node3D.new()
	holder.name = "Boundaries"
	add_child(holder)
	for i in 2:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.disable_receive_shadows = true
		var mi := MeshInstance3D.new()
		mi.mesh = ArrayMesh.new()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
		_line_nodes[i] = mi
		_rebuild_boundary_line(i)


func _boundary_x(index: int) -> int:
	return TerrainGen.ZONE_A_END if index == 0 else TerrainGen.ZONE_B_START


func _boundary_color(index: int) -> Color:
	return BOUNDARY_A_COLOR if index == 0 else BOUNDARY_B_COLOR


## 该列最高的实心方块 y（考虑玩家改动）
func surface_y(x: int, z: int) -> int:
	var h := mini(terrain.height_at(x, z), size_y - 1)
	while h + 1 < size_y and is_solid(Vector3i(x, h + 1, z)):
		h += 1
	while h > 0 and not is_solid(Vector3i(x, h, z)):
		h -= 1
	return h


func _rebuild_boundary_line(index: int) -> void:
	var mi: MeshInstance3D = _line_nodes[index]
	if mi == null:
		return
	var bx := _boundary_x(index)
	var lin := _boundary_color(index).srgb_to_linear()
	var color := Color(lin.r, lin.g, lin.b, LINE_ALPHA)
	var fx := float(bx)
	var hw := LINE_HALF_WIDTH
	var h := LINE_HEIGHT
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var add_quad := func(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		var i := verts.size()
		verts.append(a)
		verts.append(b)
		verts.append(c)
		verts.append(d)
		for k in 4:
			colors.append(color)
		indices.append_array([i, i + 1, i + 2, i, i + 2, i + 3])

	# 每段都向相邻列的高度延伸，保证整条线连续、忽略地形落差
	for z in size_z:
		var y_a := float(surface_y(bx, z)) + 1.0 + LINE_LIFT
		var y_b := y_a
		if z + 1 < size_z:
			y_b = float(surface_y(bx, z + 1)) + 1.0 + LINE_LIFT
		var lo := minf(y_a, y_b)
		var hi := maxf(y_a, y_b) + h
		var zf := float(z)
		# 竖面：平视时看到的一条线
		add_quad.call(Vector3(fx, lo, zf), Vector3(fx, lo, zf + 1.0), Vector3(fx, hi, zf + 1.0), Vector3(fx, hi, zf))
		# 顶面：俯视时看到的一条线
		add_quad.call(Vector3(fx - hw, lo, zf), Vector3(fx + hw, lo, zf), Vector3(fx + hw, lo, zf + 1.0), Vector3(fx - hw, lo, zf + 1.0))
		add_quad.call(Vector3(fx - hw, hi, zf), Vector3(fx + hw, hi, zf), Vector3(fx + hw, hi, zf + 1.0), Vector3(fx - hw, hi, zf + 1.0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = mesh
	_line_dirty[index] = false


## 方块变动后只标记对应那条线，下一帧重铺
func mark_boundary_dirty_at(x: int) -> void:
	if x >= TerrainGen.ZONE_A_END - 1 and x <= TerrainGen.ZONE_A_END:
		_line_dirty[0] = true
	if x >= TerrainGen.ZONE_B_START - 1 and x <= TerrainGen.ZONE_B_START:
		_line_dirty[1] = true


func _process(_delta: float) -> void:
	for i in 2:
		if _line_dirty[i]:
			_rebuild_boundary_line(i)


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
	mark_boundary_dirty_at(cell.x)


func chunk_of(cell: Vector3i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / float(CHUNK)), floori(float(cell.z) / float(CHUNK)))


func chunk_count_x() -> int:
	return ceili(float(size_x) / float(CHUNK))


func chunk_count_z() -> int:
	return ceili(float(size_z) / float(CHUNK))


## 每帧按距离补建区块
func update_streaming(focus: Vector3, max_builds := -1, budget_usec := -1) -> void:
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
	var budget := MAX_CHUNK_BUILDS_PER_FRAME if max_builds < 0 else max_builds
	var deadline := Time.get_ticks_usec() + (BUILD_BUDGET_USEC if budget_usec < 0 else budget_usec)
	while budget > 0 and not pending.is_empty():
		var c: Vector2i = pending.pop_front()
		if not chunks.has(c):
			_build(c)
		budget -= 1
		if Time.get_ticks_usec() >= deadline:
			break


## 还有多少区块等着重建（加载判定用）
func dirty_count() -> int:
	var n := 0
	for chunk in chunks.values():
		if chunk.dirty:
			n += 1
	return n


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
	chunk.col = col
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
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	# 热点循环里全部用事先摊平的 Packed 表，避免函数调用与数组套数组的开销
	var solid_ids := _solid_ids
	var opaque_ids := _opaque_ids
	var face_dirs := FACE_DIRS
	var face_corners := _face_corners
	var face_uv_corners := _face_uv_corners
	var face_normals := _face_normals
	var ao_flat_offsets := _ao_flat_offsets
	var ao_flat_dys := _ao_flat_dys
	var shade_colors := _shade_colors
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
				if block_id == BlockDB.AIR or solid_ids[block_id] == 0:
					continue
				var cell_pos := Vector3(gx, y, gz)
				for f in 6:
					var dir: Vector3i = face_dirs[f]
					var ny := y + dir.y
					var nb: int
					if ny < lo:
						nb = _bedrock_id
					elif ny > hi:
						nb = BlockDB.AIR
					else:
						nb = buf[base + dir.y * w2 + dir.z * w + dir.x]
					if nb != BlockDB.AIR and opaque_ids[nb] != 0:
						continue
					# 贴图里已经带方块基色，顶点色只乘面明暗 + AO
					var uv_rect: Rect2
					if dir.y > 0:
						uv_rect = _uv_top[block_id]
					elif dir.y < 0:
						uv_rect = _uv_bottom[block_id]
					else:
						uv_rect = _uv_side[block_id]
					var base_index := verts.size()
					var corners: PackedVector3Array = face_corners[f]
					var uv_corners: PackedVector2Array = face_uv_corners[f]
					var deltas: PackedInt32Array = ao_flat_offsets[f]
					var dys: PackedInt32Array = ao_flat_dys[f]
					var normal: Vector3 = face_normals[f]
					var ur := uv_rect.position
					var us := uv_rect.size
					for k in 4:
						var i3 := k * 3
						# 经典体素 AO：看这个角在面外侧那层的两个侧邻居 + 对角邻居
						var sa := 0
						var oy := y + dys[i3]
						if oy >= lo and oy <= hi:
							sa = solid_ids[buf[base + deltas[i3]]]
						var sb := 0
						oy = y + dys[i3 + 1]
						if oy >= lo and oy <= hi:
							sb = solid_ids[buf[base + deltas[i3 + 1]]]
						var sc := 0
						oy = y + dys[i3 + 2]
						if oy >= lo and oy <= hi:
							sc = solid_ids[buf[base + deltas[i3 + 2]]]
						var ao_level := sa + sb + sc
						if sa != 0 and sb != 0:
							ao_level = 3
						verts.append(cell_pos + corners[k])
						normals.append(normal)
						colors.append(shade_colors[f * 4 + ao_level])
						var uvc := uv_corners[k]
						uvs.append(Vector2(ur.x + uvc.x * us.x, ur.y + uvc.y * us.y))
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
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _material)
	chunk.mesh_instance.mesh = mesh
	# 注意：Jolt 物理后端不会因为 ConcavePolygonShape3D 内容变化就刷新静态体，
	# 挖掉方块后碰撞会一直卡在原来的面上（钻头/激光射线打空）。所以每次重建都换一个新的
	# StaticBody3D + CollisionShape3D。
	var new_shape := ConcavePolygonShape3D.new()
	new_shape.set_faces(faces)
	chunk.shape = new_shape
	if chunk.body != null:
		chunk.body.free()
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = new_shape
	body.add_child(col)
	chunk.body = body
	chunk.col = col
	chunk.add_child(body)
	chunk.built = true


## 该格是否允许建造/破坏（现在全图都可建造，保留接口给以后的规则用）
func is_buildable(cell: Vector3i) -> bool:
	return in_bounds(cell)


## 射线检测：返回 {cell, normal, point}，未命中返回空字典
func raycast(from: Vector3, to: Vector3) -> Dictionary:
	# 自己做体素 DDA：Jolt 的凹陷形状在挖掉方块后不一定立刻刷新，
	# 而瞄准/激光/钻头都吃这条射线，所以绕开物理引擎，直接按方块数据步进。
	var dir := to - from
	var dist := dir.length()
	if dist < 0.0001:
		return {}
	dir /= dist
	var cell := Vector3i(floori(from.x), floori(from.y), floori(from.z))
	if is_solid(cell):
		return {"cell": cell, "normal": Vector3i.UP, "point": from}
	var step_x := 0
	var step_y := 0
	var step_z := 0
	var t_max_x := INF
	var t_max_y := INF
	var t_max_z := INF
	var t_delta_x := INF
	var t_delta_y := INF
	var t_delta_z := INF
	if dir.x > 0.0:
		step_x = 1
		t_delta_x = 1.0 / dir.x
		t_max_x = (float(cell.x + 1) - from.x) / dir.x
	elif dir.x < 0.0:
		step_x = -1
		t_delta_x = -1.0 / dir.x
		t_max_x = (float(cell.x) - from.x) / dir.x
	if dir.y > 0.0:
		step_y = 1
		t_delta_y = 1.0 / dir.y
		t_max_y = (float(cell.y + 1) - from.y) / dir.y
	elif dir.y < 0.0:
		step_y = -1
		t_delta_y = -1.0 / dir.y
		t_max_y = (float(cell.y) - from.y) / dir.y
	if dir.z > 0.0:
		step_z = 1
		t_delta_z = 1.0 / dir.z
		t_max_z = (float(cell.z + 1) - from.z) / dir.z
	elif dir.z < 0.0:
		step_z = -1
		t_delta_z = -1.0 / dir.z
		t_max_z = (float(cell.z) - from.z) / dir.z
	var normal := Vector3i.ZERO
	var t := 0.0
	while t <= dist:
		if t_max_x < t_max_y and t_max_x < t_max_z:
			cell.x += step_x
			t = t_max_x
			t_max_x += t_delta_x
			normal = Vector3i(-step_x, 0, 0)
		elif t_max_y < t_max_z:
			cell.y += step_y
			t = t_max_y
			t_max_y += t_delta_y
			normal = Vector3i(0, -step_y, 0)
		else:
			cell.z += step_z
			t = t_max_z
			t_max_z += t_delta_z
			normal = Vector3i(0, 0, -step_z)
		if t > dist:
			break
		if is_solid(cell):
			return {"cell": cell, "normal": normal, "point": from + dir * t}
	return {}
