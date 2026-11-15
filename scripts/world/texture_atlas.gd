extends RefCounted
## 程序生成的像素风方块贴图图集（不读取任何外部图片素材）。
##
## 16×16 像素一格，8×8 格拼成 128×128 的图集。
## 每种方块占 3 格：顶面 / 底面 / 侧面，格子下标 = 方块 id * 3 + 面类型。
## 贴图里已经烘焙了方块基色（来自 data/blocks/*.json），
## 顶点色只负责面明暗和环境光遮蔽（AO），避免同一个颜色被乘两次。
##
## 画风（2026-11 统一）：**双色低噪**。
## 每个面只用两种颜色——方块基色 + 同色相暗一档的第二色（TONE_DARK 比例），
## 用 4×4 Bayer 有序抖动 + 2×2 块哈希决定每个像素落在哪一档：
## 近看是干净的像素噪点，远看还是整块纯色，不会像旧版那样大大小小的深浅斑块糊成一团。
## 唯二例外：草方块侧面用「草色 + 泥土色」两种纯色（不做抖动）；矿石面在石头双色上再加矿色（+1 个高光色）保证可辨识。
##
## 所有像素都用确定性哈希逐像素画出来：同样的方块数据每次生成结果完全一致，
## 不会有随机闪烁，也不依赖任何外部资源。

const CELL := 16
const COLS := 8
const ROWS := 8
const WIDTH := COLS * CELL
const HEIGHT := ROWS * CELL
const CELLS := COLS * ROWS

## 面类型（voxel_world 里按这个顺序建缓存表）
const FACE_TOP := 0
const FACE_BOTTOM := 1
const FACE_SIDE := 2

## 第二色（暗色）= 主色 × 这个比例。所有方块统一，保证整体对比度一致、不刺眼。
const TONE_DARK := 0.86

## Bayer 4×4 有序抖动阈值表（0..15）。用有序抖动而不是纯随机，
## 噪点会排成稳定的像素网点，放大看是像素风的规则颗粒，而不是脏噪。
const BAYER4 := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

## 生成的图集图像（RGBA8，未使用的格子透明）
var image: Image
## 给材质用的 GPU 贴图
var texture: ImageTexture

var _cell_rects: Array = []


## 按方块表生成整张图集。可重复调用（会重新生成一张新图）。
func build(block_db) -> void:
	image = Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	_cell_rects.resize(CELLS)
	for i in CELLS:
		_cell_rects[i] = _cell_uv_rect(i)

	# 草方块的底面/侧面、矿石的石头底子会借用其他方块的颜色
	var dirt_def = block_db.get_def(block_db.id_of("dirt"))
	var dirt_color: Color = dirt_def.color if dirt_def != null else Color(0.53, 0.38, 0.26)
	var stone_def = block_db.get_def(block_db.id_of("stone"))
	var stone_color: Color = stone_def.color if stone_def != null else Color(0.5, 0.5, 0.51)

	for def in block_db.defs:
		var top: Color = def.top_color if def.has_top else def.color
		# 草方块：底面是泥土，侧面是「泥土 + 顶上一圈草边」
		var bottom_mat := str(def.name)
		var bottom_color: Color = def.color
		var side_mat := str(def.name)
		var side_color: Color = def.color
		if def.name == "grass":
			bottom_mat = "dirt"
			bottom_color = dirt_color
			side_mat = "grass_side"
			side_color = def.color
		var top_mat := str(def.name)
		_paint(def.id * 3 + FACE_TOP, top_mat, top, stone_color, dirt_color, def.id)
		_paint(def.id * 3 + FACE_BOTTOM, bottom_mat, bottom_color, stone_color, dirt_color, def.id + 100)
		_paint(def.id * 3 + FACE_SIDE, side_mat, side_color, stone_color, dirt_color, def.id + 200)
	texture = ImageTexture.create_from_image(image)


## 方块某个面在图集里的格子下标
func cell_index(block_id: int, face_type: int) -> int:
	return block_id * 3 + face_type


## 某个面的 UV 矩形（已内缩半格像素，避免最近邻采样取到隔壁格子）
func uv_rect(block_id: int, face_type: int) -> Rect2:
	var cell := cell_index(block_id, face_type)
	if cell < 0 or cell >= _cell_rects.size():
		return Rect2(0.0, 0.0, 1.0, 1.0)
	return _cell_rects[cell]


func _cell_uv_rect(cell: int) -> Rect2:
	var col := cell % COLS
	var row := cell / COLS
	var x := (float(col * CELL) + 0.5) / float(WIDTH)
	var y := (float(row * CELL) + 0.5) / float(HEIGHT)
	return Rect2(x, y, float(CELL - 1) / float(WIDTH), float(CELL - 1) / float(HEIGHT))


func _paint(cell: int, material: String, base: Color, stone: Color, dirt: Color, seed: int) -> void:
	if material == "air":
		return
	if cell < 0 or cell >= CELLS:
		push_warning("贴图图集格子越界：%d（方块贴图会退化成纯色）" % cell)
		return
	var ox := (cell % COLS) * CELL
	var oy := (cell / COLS) * CELL
	match material:
		"grass":
			# 草顶：主色 + 略暗的草簇
			_two_tone(ox, oy, base, 0.26, seed)
		"grass_side":
			_paint_grass_side(ox, oy, base, dirt, seed)
		"dirt":
			_two_tone(ox, oy, base, 0.30, seed)
		"sand":
			_two_tone(ox, oy, base, 0.14, seed)
		"stone":
			_two_tone(ox, oy, base, 0.30, seed)
		"coal_ore":
			_paint_ore(ox, oy, stone, seed, Color(0.07, 0.07, 0.08), Color(0.34, 0.34, 0.36))
		"copper_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(0.42, 0.72, 0.52))
		"iron_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(0.72, 0.74, 0.78))
		"gold_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(1.0, 0.86, 0.42))
		"bedrock":
			# 基岩：整张图本来就暗，用更暗一档的第二色，仍然只有两种颜色
			_two_tone(ox, oy, base, 0.38, seed)
		"planks":
			_paint_planks(ox, oy, base, seed)
		_:
			_two_tone(ox, oy, base, 0.30, seed)


# ---------------------------------------------------------------- 通用工具

## 确定性哈希（纯整数运算，跨平台结果一致）
func _hash(x: int, y: int, seed: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ seed * 83492791
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return h & 0x7fffffff


## 由坐标+种子得到 0..1 的确定性伪随机数
func _rand(x: int, y: int, seed: int) -> float:
	return float(_hash(x, y, seed) % 8192) / 8192.0


func _bayer(x: int, y: int) -> float:
	return float(BAYER4[(y & 3) * 4 + (x & 3)]) / 16.0


func _color_scale(c: Color, k: float) -> Color:
	return Color(
		clampf(c.r * k, 0.0, 1.0),
		clampf(c.g * k, 0.0, 1.0),
		clampf(c.b * k, 0.0, 1.0),
		1.0)


func _mix(a: Color, b: Color, t: float) -> Color:
	return Color(
		a.r + (b.r - a.r) * t,
		a.g + (b.g - a.g) * t,
		a.b + (b.b - a.b) * t,
		1.0)


func _put(ox: int, oy: int, x: int, y: int, c: Color) -> void:
	if x < 0 or x >= CELL or y < 0 or y >= CELL:
		return
	image.set_pixel(ox + x, oy + y, c)


# ---------------------------------------------------------------- 双色低噪底纹

## 双色低噪底纹：light 为主色，dark = light × TONE_DARK。
## density 是暗色像素的占比（0..1）。抖动值 = 有序抖动 × 0.55 + 2×2 块哈希 × 0.45：
## 有规律的网点 + 成簇的块，既有像素风颗粒感，又不会出现高对比的单个脏点。
func _two_tone(ox: int, oy: int, light: Color, density: float, seed: int) -> void:
	var dark := _color_scale(light, TONE_DARK)
	for y in CELL:
		for x in CELL:
			var t := _bayer(x, y) * 0.55 + _rand(x >> 1, y >> 1, seed) * 0.45
			_put(ox, oy, x, y, dark if t < density else light)


# ---------------------------------------------------------------- 各种材质

## 草方块侧面：泥土纯色打底 + 顶上 2~5 像素不规则的草边。
## 这个面是「草色 + 泥土色」两种纯色（不做抖动），因为两种颜色已经够区分了。
func _paint_grass_side(ox: int, oy: int, grass: Color, dirt: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			_put(ox, oy, x, y, dirt)
	for x in CELL:
		var depth := 2 + int(_rand(x, 0, seed) * 4.0)
		if _rand(x, 1, seed) < 0.18:
			depth += 1
		for y in depth:
			_put(ox, oy, x, y, grass)


## 矿石：石头双色底 + 几团矿点（2×2 团 + 零星高光像素）
func _paint_ore(ox: int, oy: int, stone: Color, seed: int, ore: Color, accent: Color) -> void:
	_two_tone(ox, oy, stone, 0.30, seed)
	for i in 6:
		var cx := 1 + _hash(i, 1, seed + 5) % 12
		var cy := 1 + _hash(i, 2, seed + 9) % 12
		# 2×2 的小矿团
		for px in 2:
			for py in 2:
				_put(ox, oy, cx + px, cy + py, ore)
		if _hash(i, 3, seed) % 2 == 0:
			_put(ox, oy, cx + 2, cy, accent)
		if _hash(i, 4, seed) % 2 == 0:
			_put(ox, oy, cx, cy + 2, accent)


## 木板：主色 + 暗一档，水平板缝 + 错开的竖向拼缝都直接用暗色画（还是两种颜色）
func _paint_planks(ox: int, oy: int, base: Color, seed: int) -> void:
	var dark := _color_scale(base, 0.80)
	for y in CELL:
		var board := y / 4
		var seam_x := 2 + _hash(board, 5, seed) % 11
		for x in CELL:
			var is_dark := false
			if y % 4 == 3:
				is_dark = true          # 水平板缝
			elif x == seam_x:
				is_dark = true          # 竖向拼缝
			else:
				# 木纹：稀疏短纹，仍然只用暗色
				var t := _bayer(x, y) * 0.6 + _rand(board, x >> 2, seed + 9) * 0.4
				is_dark = t < 0.13
			_put(ox, oy, x, y, dark if is_dark else base)
