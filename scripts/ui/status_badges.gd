extends RefCounted
## 单位 / 建筑头顶的「状态图标」：程序化生成的贴图，不用任何外部素材（规避版权）
##
## 用法：
##   var badge := StatusBadges.make_sprite(self, Vector3(0, height, 0))
##   StatusBadges.set_kind(badge, StatusBadges.KIND_NO_POWER)
##   StatusBadges.set_kind(badge, StatusBadges.KIND_NONE)   # 隐藏

enum Kind {
	NONE = 0,
	NO_POWER = 1,    ## 没电：黄色闪电
	BURIED = 2,      ## 被方块埋住 / 占地被占：棕色方块 + 红叉
	FOUNDATION = 3,  ## 地基不牢：橙色警示三角
	STALLED = 4,     ## 代码报错 / 停机：红色感叹号
}

const TEXTURE_SIZE := 64
const PIXEL_SIZE := 0.005          ## 每个像素多少米（64 像素 ≈ 0.45 米）
const BADGE_NAME := "StatusBadge"

static var _cache: Dictionary = {}


## 取某个状态的图标贴图（首次调用时生成，之后复用）
static func texture(kind: int) -> Texture2D:
	if _cache.has(kind):
		return _cache[kind]
	var img := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match kind:
		Kind.NO_POWER:
			_draw_disc(img, Color(0.05, 0.06, 0.08, 0.85))
			_draw_ring(img, Color(0.98, 0.82, 0.25, 1.0), 2)
			_draw_bolt(img, Color(1.0, 0.85, 0.2, 1.0))
		Kind.BURIED:
			_draw_disc(img, Color(0.05, 0.06, 0.08, 0.85))
			_draw_ring(img, Color(0.80, 0.55, 0.32, 1.0), 2)
			_draw_cubes(img, Color(0.72, 0.48, 0.26, 1.0), Color(0.5, 0.32, 0.16, 1.0))
			_draw_cross(img, Color(0.95, 0.25, 0.2, 1.0))
		Kind.FOUNDATION:
			_draw_triangle(img, Color(0.98, 0.62, 0.15, 1.0), Color(0.35, 0.18, 0.02, 1.0))
			_draw_exclamation(img, Color(0.25, 0.12, 0.0, 1.0))
		Kind.STALLED:
			_draw_disc(img, Color(0.05, 0.06, 0.08, 0.85))
			_draw_ring(img, Color(0.95, 0.25, 0.2, 1.0), 2)
			_draw_exclamation(img, Color(0.98, 0.3, 0.25, 1.0))
		_:
			img.fill(Color(0, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	_cache[kind] = tex
	return tex


## 给某个节点挂一个状态图标（默认隐藏）
static func make_sprite(parent: Node3D, offset: Vector3) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.name = BADGE_NAME
	sprite.texture = texture(Kind.NONE)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.shaded = false
	sprite.no_depth_test = true
	sprite.render_priority = 20
	sprite.pixel_size = PIXEL_SIZE
	sprite.position = offset
	sprite.visible = false
	parent.add_child(sprite)
	return sprite


## 设置图标状态（传 NONE 就隐藏）；没有 sprite 时安全返回
static func set_kind(sprite: Sprite3D, kind: int) -> void:
	if sprite == null:
		return
	if kind == Kind.NONE:
		sprite.visible = false
		sprite.set_meta("kind", Kind.NONE)
		return
	sprite.set_meta("kind", kind)
	sprite.texture = texture(kind)
	sprite.visible = true


## 当前图标状态（给测试 / 调用方查）
static func kind_of(sprite: Sprite3D) -> int:
	if sprite == null:
		return Kind.NONE
	return int(sprite.get_meta("kind", Kind.NONE))


# ---------------- 画图小工具（全部手写像素，零依赖） ----------------

static func _put(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= TEXTURE_SIZE or y >= TEXTURE_SIZE:
		return
	if c.a >= 0.999:
		img.set_pixel(x, y, c)
	else:
		var base := img.get_pixel(x, y)
		img.set_pixel(x, y, base.lerp(c, c.a))


static func _draw_disc(img: Image, c: Color) -> void:
	var r := TEXTURE_SIZE * 0.47
	var cx := TEXTURE_SIZE * 0.5
	var cy := TEXTURE_SIZE * 0.5
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var d := Vector2(float(x) - cx + 0.5, float(y) - cy + 0.5).length()
			if d <= r:
				_put(img, x, y, c)


static func _draw_ring(img: Image, c: Color, width: int) -> void:
	var r := TEXTURE_SIZE * 0.47
	var cx := TEXTURE_SIZE * 0.5
	var cy := TEXTURE_SIZE * 0.5
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var d := Vector2(float(x) - cx + 0.5, float(y) - cy + 0.5).length()
			if d <= r and d >= r - float(width):
				_put(img, x, y, c)


## 闪电（没电）
static func _draw_bolt(img: Image, c: Color) -> void:
	var pts := [
		Vector2(36, 8), Vector2(22, 34), Vector2(31, 34),
		Vector2(26, 56), Vector2(44, 28), Vector2(34, 28),
	]
	_fill_poly(img, pts, c)


## 三个小方块 + 红叉（被埋住）
static func _draw_cubes(img: Image, face: Color, shade: Color) -> void:
	for row in 2:
		for col in 2:
			var x0 := 16 + col * 18
			var y0 := 18 + row * 18
			for y in 14:
				for x in 14:
					var c := face
					if x > 10 or y > 10:
						c = shade
					_put(img, x0 + x, y0 + y, c)


static func _draw_cross(img: Image, c: Color) -> void:
	for i in 22:
		_put(img, 12 + i, 12 + i, c)
		_put(img, 12 + i, 34 - i, c)
	for d in range(-2, 3):
		for i in 22:
			_put(img, 12 + i + d, 12 + i, c)
			_put(img, 12 + i + d, 34 - i, c)


## 警示三角（地基不牢）
static func _draw_triangle(img: Image, fill: Color, edge: Color) -> void:
	var pts := [Vector2(32, 6), Vector2(58, 54), Vector2(6, 54)]
	_fill_poly(img, pts, fill)
	_stroke_poly(img, pts, edge, 3)


static func _draw_exclamation(img: Image, c: Color) -> void:
	for y in range(22, 38):
		for x in range(29, 35):
			_put(img, x, y, c)
	for y in range(42, 48):
		for x in range(29, 35):
			_put(img, x, y, c)


static func _fill_poly(img: Image, pts: Array, c: Color) -> void:
	var min_y := TEXTURE_SIZE
	var max_y := 0
	for p in pts:
		min_y = mini(min_y, int(floor(p.y)))
		max_y = maxi(max_y, int(ceil(p.y)))
	for y in range(max_y, min_y - 1, -1):
		var xs: Array = []
		for i in pts.size():
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			if (a.y <= float(y) and b.y > float(y)) or (b.y <= float(y) and a.y > float(y)):
				var t: float = (float(y) - a.y) / (b.y - a.y)
				xs.append(a.x + (b.x - a.x) * t)
		xs.sort()
		var i := 0
		while i + 1 < xs.size():
			var x_from := int(ceil(xs[i]))
			var x_to := int(floor(xs[i + 1]))
			for x in range(x_from, x_to + 1):
				_put(img, x, y, c)
			i += 2


static func _stroke_poly(img: Image, pts: Array, c: Color, width: int) -> void:
	for i in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		var steps := int(maxf(absf(b.x - a.x), absf(b.y - a.y)) * 2.0) + 1
		for s in steps + 1:
			var t := float(s) / float(steps)
			var p := a.lerp(b, t)
			for dx in range(-width, width + 1):
				for dy in range(-width, width + 1):
					if absf(float(dx)) + absf(float(dy)) <= float(width):
						_put(img, int(p.x) + dx, int(p.y) + dy, c)
