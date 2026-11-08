extends RefCounted
## 程序生成的像素风方块贴图图集（不读取任何外部图片素材）。
##
## 16×16 像素一格，8×8 格拼成 128×128 的图集。
## 每种方块占 3 格：顶面 / 底面 / 侧面，格子下标 = 方块 id * 3 + 面类型。
## 贴图里已经烘焙了方块基色（来自 data/blocks/*.json），
## 顶点色只负责面明暗和环境光遮蔽（AO），避免同一个颜色被乘两次。
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
			_paint_grass_top(ox, oy, base, seed)
		"grass_side":
			_paint_grass_side(ox, oy, base, dirt, seed)
		"dirt":
			_paint_dirt(ox, oy, base, seed)
		"sand":
			_paint_sand(ox, oy, base, seed)
		"stone":
			_paint_stone(ox, oy, base, seed)
		"coal_ore":
			_paint_ore(ox, oy, stone, seed, Color(0.07, 0.07, 0.08), Color(0.34, 0.34, 0.36))
		"copper_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(0.42, 0.72, 0.52))
		"iron_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(0.72, 0.74, 0.78))
		"gold_ore":
			_paint_ore(ox, oy, stone, seed, base, Color(1.0, 0.86, 0.42))
		"bedrock":
			_paint_bedrock(ox, oy, base, seed)
		"planks":
			_paint_planks(ox, oy, base, seed)
		_:
			_paint_stone(ox, oy, base, seed)


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


# ---------------------------------------------------------------- 各种材质

## 草方块顶面：绿色噪点 + 少量深浅草簇
func _paint_grass_top(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			var fine := _rand(x, y, seed) - 0.5
			var clump := _rand(x >> 1, y >> 1, seed + 31) - 0.5
			var k := 1.0 + fine * 0.30 + clump * 0.24
			var r := _rand(x, y, seed + 7)
			if r < 0.07:
				k -= 0.15
			elif r > 0.95:
				k += 0.12
			_put(ox, oy, x, y, _color_scale(base, k))


## 泥土：棕色颗粒 + 零星小石子/深色土块
func _paint_dirt(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			var fine := _rand(x, y, seed) - 0.5
			var clump := _rand(x >> 1, y >> 1, seed + 53) - 0.5
			var k := 1.0 + fine * 0.30 + clump * 0.22
			var r := _rand(x, y, seed + 11)
			if r < 0.05:
				k -= 0.22
			elif r > 0.96:
				k += 0.14
			if _rand(x >> 1, y >> 1, seed + 71) < 0.13:
				k -= 0.12
			_put(ox, oy, x, y, _color_scale(base, k))


## 沙子：浅色细颗粒，对比度低一点
func _paint_sand(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			var fine := _rand(x, y, seed) - 0.5
			var clump := _rand(x >> 1, y >> 1, seed + 17) - 0.5
			var k := 1.0 + fine * 0.16 + clump * 0.10
			var r := _rand(x, y, seed + 5)
			if r < 0.07:
				k -= 0.10
			elif r > 0.94:
				k += 0.08
			_put(ox, oy, x, y, _color_scale(base, k))


## 石头：灰色噪点 + 大小不一的斑块和深色矿物点
func _paint_stone(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			var fine := _rand(x, y, seed) - 0.5
			var clump := _rand(x >> 1, y >> 1, seed + 19) - 0.5
			var k := 1.0 + fine * 0.22 + clump * 0.28
			var blotch := _rand(x >> 1, y >> 1, seed + 43)
			if blotch < 0.16:
				k -= 0.15
			elif blotch > 0.88:
				k += 0.10
			var r := _rand(x, y, seed + 3)
			if r < 0.04:
				k -= 0.30
			elif r > 0.97:
				k += 0.16
			_put(ox, oy, x, y, _color_scale(base, k))


## 草方块侧面：泥土打底，顶上覆盖 2~5 像素不规则的草边
func _paint_grass_side(ox: int, oy: int, grass: Color, dirt: Color, seed: int) -> void:
	_paint_dirt(ox, oy, dirt, seed + 17)
	for x in CELL:
		var depth := 2 + int(_rand(x, 0, seed) * 4.0)
		if _rand(x, 1, seed) < 0.18:
			depth += 1
		for y in depth:
			var fine := _rand(x, y, seed + 21) - 0.5
			var k := 1.0 + fine * 0.30
			if y == depth - 1:
				k -= 0.12  # 最底下一行略暗，像草垂下来
			_put(ox, oy, x, y, _color_scale(grass, k))


## 矿石：石头底子上撒几团矿点（煤矿黑点/铜矿铜色+绿锈）
func _paint_ore(ox: int, oy: int, stone: Color, seed: int, ore: Color, accent: Color) -> void:
	_paint_stone(ox, oy, stone, seed)
	for i in 6:
		var cx := 1 + _hash(i, 1, seed + 5) % 12
		var cy := 1 + _hash(i, 2, seed + 9) % 12
		var color := ore if i % 3 != 0 else _mix(ore, accent, 0.5)
		# 2×2 的小矿团，再随机多挂一两颗
		for px in 2:
			for py in 2:
				_put(ox, oy, cx + px, cy + py, color)
		if _hash(i, 3, seed) % 2 == 0:
			_put(ox, oy, cx + 2, cy, _mix(color, Color.BLACK, 0.25))
		if _hash(i, 4, seed) % 2 == 0:
			_put(ox, oy, cx, cy + 2, accent)


## 基岩：深灰高对比斑块 + 黑色裂缝
func _paint_bedrock(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		for x in CELL:
			var patch := _rand(x >> 2, y >> 2, seed + 13) - 0.5
			var clump := _rand(x >> 1, y >> 1, seed + 41) - 0.5
			var fine := _rand(x, y, seed) - 0.5
			var k := 1.0 + patch * 0.45 + clump * 0.35 + fine * 0.20
			if _rand(x >> 1, y >> 1, seed + 77) < 0.14:
				k -= 0.40  # 黑色裂缝
			_put(ox, oy, x, y, _color_scale(base, k))


## 木板：水平木板 + 板缝 + 错开的竖向拼缝 + 木纹
func _paint_planks(ox: int, oy: int, base: Color, seed: int) -> void:
	for y in CELL:
		var board := y / 4
		var row := y % 4
		var board_k := 1.0 + (float(_hash(board, 0, seed) % 100) / 100.0 - 0.5) * 0.16
		var seam_x := 2 + _hash(board, 5, seed) % 11
		for x in CELL:
			var k := board_k
			k += (_rand(x, y, seed + board * 31) - 0.5) * 0.14
			# 顺纹方向的长条纹理
			if _rand(x >> 3, y, seed + 9) < 0.16:
				k -= 0.10
			if row == 3:
				k -= 0.22  # 水平板缝
			elif row == 0:
				k += 0.05
			if x == seam_x:
				k -= 0.20  # 竖向拼缝
			_put(ox, oy, x, y, _color_scale(base, k))
