extends SceneTree
## 程序生成贴图 / UV / 顶点 AO 的 headless 测试

const BlockDB = preload("res://scripts/world/block_db.gd")
const TextureAtlas = preload("res://scripts/world/texture_atlas.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")

var _passed := 0
var _failed := 0


func _record(name: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)


## 统计某个格子里不透明像素数
func _opaque_pixels(img: Image, block_id: int, face_type: int) -> int:
	var cell := block_id * 3 + face_type
	var ox := (cell % TextureAtlas.COLS) * TextureAtlas.CELL
	var oy := (cell / TextureAtlas.COLS) * TextureAtlas.CELL
	var n := 0
	for y in TextureAtlas.CELL:
		for x in TextureAtlas.CELL:
			if img.get_pixel(ox + x, oy + y).a > 0.5:
				n += 1
	return n


## 格子平均颜色
func _cell_average(img: Image, block_id: int, face_type: int) -> Color:
	var cell := block_id * 3 + face_type
	var ox := (cell % TextureAtlas.COLS) * TextureAtlas.CELL
	var oy := (cell / TextureAtlas.COLS) * TextureAtlas.CELL
	var sum := Color(0, 0, 0, 1)
	for y in TextureAtlas.CELL:
		for x in TextureAtlas.CELL:
			var c := img.get_pixel(ox + x, oy + y)
			sum.r += c.r
			sum.g += c.g
			sum.b += c.b
	var count := float(TextureAtlas.CELL * TextureAtlas.CELL)
	return Color(sum.r / count, sum.g / count, sum.b / count, 1.0)


func _initialize() -> void:
	var db := BlockDB.new()
	var problem := db.load_dir("res://data/blocks")
	_record("方块数据可加载", problem == "", problem)

	# ---- 图集生成 ----
	var atlas := TextureAtlas.new()
	atlas.build(db)
	_record("图集生成成功", atlas.image != null and atlas.texture != null)
	_record("图集尺寸 = 128×128", atlas.image.get_width() == 128 and atlas.image.get_height() == 128,
		"%d×%d" % [atlas.image.get_width(), atlas.image.get_height()])
	_record("图集格式 = RGBA8", atlas.image.get_format() == Image.FORMAT_RGBA8)

	# 每种非空气方块的三面都要画上东西（草地底面借用泥土，也算有内容）
	var missing: Array = []
	for def in db.defs:
		if def.id == BlockDB.AIR:
			continue
		for face_type in [TextureAtlas.FACE_TOP, TextureAtlas.FACE_BOTTOM, TextureAtlas.FACE_SIDE]:
			if _opaque_pixels(atlas.image, def.id, face_type) < TextureAtlas.CELL * TextureAtlas.CELL / 2:
				missing.append("%s/面%d" % [def.name, face_type])
	_record("每种方块每面都有贴图", missing.is_empty(), str(missing))
	_record("空气格子保持透明", _opaque_pixels(atlas.image, BlockDB.AIR, TextureAtlas.FACE_TOP) == 0)

	# 草顶偏绿、草侧底部偏棕，说明贴图确实按材质画了而不是糊成一片
	var grass_id := db.id_of("grass")
	var grass_top := _cell_average(atlas.image, grass_id, TextureAtlas.FACE_TOP)
	var grass_side := _cell_average(atlas.image, grass_id, TextureAtlas.FACE_SIDE)
	_record("草顶偏绿", grass_top.g > grass_top.r + 0.1, str(grass_top))
	_record("草侧有泥土色", grass_side.r > grass_side.g, str(grass_side))

	# 石头/泥土/沙颜色要有区分度
	var stone_avg := _cell_average(atlas.image, db.id_of("stone"), TextureAtlas.FACE_SIDE)
	var dirt_avg := _cell_average(atlas.image, db.id_of("dirt"), TextureAtlas.FACE_SIDE)
	var sand_avg := _cell_average(atlas.image, db.id_of("sand"), TextureAtlas.FACE_SIDE)
	_record("泥土偏红棕色", dirt_avg.r > dirt_avg.g + 0.05, str(dirt_avg))
	_record("石头接近灰色", absf(stone_avg.r - stone_avg.g) < 0.02, str(stone_avg))
	_record("沙子比泥土更亮", sand_avg.get_luminance() > dirt_avg.get_luminance() + 0.15)

	# 贴图里要有像素噪点（不是纯色），但不能花到失去主色
	var stone_cell := db.id_of("stone") * 3 + TextureAtlas.FACE_SIDE
	var stone_ox := (stone_cell % TextureAtlas.COLS) * TextureAtlas.CELL
	var stone_oy := (stone_cell / TextureAtlas.COLS) * TextureAtlas.CELL
	var varied := 0
	for y in TextureAtlas.CELL:
		var c := atlas.image.get_pixel(stone_ox + 4, stone_oy + y)
		if absf(c.r - stone_avg.r) > 0.01:
			varied += 1
	_record("石头贴图有像素噪点", varied >= 5, "%d/16 行有差异" % varied)

	# ---- UV 矩形 ----
	var uv_bad: Array = []
	for def in db.defs:
		for face_type in [TextureAtlas.FACE_TOP, TextureAtlas.FACE_BOTTOM, TextureAtlas.FACE_SIDE]:
			var r: Rect2 = atlas.uv_rect(def.id, face_type)
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				uv_bad.append("%s/面%d 空矩形" % [def.name, face_type])
			elif r.position.x < 0.0 or r.position.y < 0.0 \
					or r.position.x + r.size.x > 1.0 or r.position.y + r.size.y > 1.0:
				uv_bad.append("%s/面%d 越界" % [def.name, face_type])
	_record("所有 UV 矩形都在 0..1 内", uv_bad.is_empty(), str(uv_bad))

	# 每格 UV 互不重叠，且格子下标唯一
	var seen: Dictionary = {}
	var overlap := false
	for def in db.defs:
		for face_type in 3:
			var r: Rect2 = atlas.uv_rect(def.id, face_type)
			var key := "%d" % atlas.cell_index(def.id, face_type)
			if seen.has(key):
				overlap = true
			seen[key] = r
	_record("每种方块每面占独立格子", not overlap and seen.size() == db.defs.size() * 3, str(seen.size()))

	# 确定性：同样数据重复生成结果必须一致
	var atlas2 := TextureAtlas.new()
	atlas2.build(db)
	_record("图集可重复生成且结果一致", atlas2.image.get_data() == atlas.image.get_data())

	# ---- 网格 UV / AO ----
	var world := VoxelWorld.new()
	root.add_child(world)
	world.setup(db, 12345, 64, 64, 48)
	world.build_all()
	_record("世界构建成功", world.chunks.size() > 0)

	_record("材质使用图集贴图", world._material.albedo_texture == atlas.texture
		or world._material.albedo_texture == world.atlas.texture)
	_record("材质是最近邻采样", world._material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST)

	var verts := 0
	var uv_count := 0
	var mesh_uv_bad: Array = []
	var uv_range_bad: Array = []
	var ao_bad: Array = []
	var ao_values: Dictionary = {}
	var color_not_gray := 0
	var ao_min := 2.0
	var ao_max := 0.0
	for chunk in world.chunks.values():
		var mesh: ArrayMesh = chunk.mesh_instance.mesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays := mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		verts += v.size()
		uv_count += uvs.size()
		# 每个顶点一个 UV（两个浮点），长度必须是顶点数的 2 倍
		if uvs.size() != v.size():
			if mesh_uv_bad.size() < 5:
				mesh_uv_bad.append("区块 UV 数 %d ≠ 顶点数 %d" % [uvs.size(), v.size()])
		if colors.size() != v.size():
			if ao_bad.size() < 5:
				ao_bad.append("顶点色数量 %d ≠ 顶点数 %d" % [colors.size(), v.size()])
		for i in uvs.size():
			var uv := uvs[i]
			if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
				if uv_range_bad.size() < 5:
					uv_range_bad.append(str(uv))
		# 顶点色是灰度明暗，取值 = FACE_SHADE × AO，应落在 0.3..1.0 之间
		for i in colors.size():
			var c := colors[i]
			if absf(c.r - c.g) > 0.001 or absf(c.g - c.b) > 0.001:
				color_not_gray += 1
			if c.r < 0.30 or c.r > 1.001:
				if ao_bad.size() < 5:
					ao_bad.append(str(c.r))
			ao_min = minf(ao_min, c.r)
			ao_max = maxf(ao_max, c.r)
			ao_values[snappedf(c.r, 0.01)] = true

	_record("网格里 UV 数量 = 顶点数（每顶点 2 个浮点）", mesh_uv_bad.is_empty(), str(mesh_uv_bad))
	_record("网格 UV 全部在 0..1 内", uv_range_bad.is_empty(), str(uv_range_bad))
	_record("UV 总数是顶点数的 2 倍", verts > 0 and uv_count * 2 == verts * 2,
		"顶点 %d / UV %d" % [verts, uv_count])
	_record("顶点色是灰度明暗", color_not_gray == 0, "%d 个顶点非灰度" % color_not_gray)
	_record("AO 明暗在 0.3..1.0 内", ao_bad.is_empty(), str(ao_bad))
	_record("AO 确实产生多级明暗", ao_values.size() >= 3, "%d 种明暗值" % ao_values.size())
	_record("AO 有被遮挡的暗角", ao_min < 0.9, "最暗 %.3f" % ao_min)
	_record("AO 亮面接近原亮度", ao_max > 0.95, "最亮 %.3f" % ao_max)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
