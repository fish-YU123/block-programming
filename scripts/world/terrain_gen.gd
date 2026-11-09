extends RefCounted
## 地形生成：噪声高度场 + 分层 + 矿石散布。有限地图，尺寸由世界设定。

const BlockDB = preload("res://scripts/world/block_db.gd")

const BASE_HEIGHT := 26

## 地图分带：蓝队 [0, zone_a_end)，中立区 [zone_a_end, zone_b_start)，红队 [zone_b_start, 世界宽)
const MAP_WIDTH := 256
const ZONE_A_END := 100
const ZONE_B_START := 156
const NEUTRAL_HEIGHT := 16.0
const HILL_AMP := 6.0
const DETAIL_AMP := 1.0

var _db: BlockDB
var _continent := FastNoiseLite.new()
var _hills := FastNoiseLite.new()
var _detail := FastNoiseLite.new()

var id_air := 0
var id_grass := 1
var id_dirt := 2
var id_stone := 3
var id_sand := 4
var id_coal := 5
var id_copper := 6
var id_iron := 9
var id_gold := 10
var id_bedrock := 7

var _height_cache := {}


func setup(db: BlockDB, world_seed: int) -> void:
	_db = db
	id_air = db.id_of("air")
	id_grass = db.id_of("grass")
	id_dirt = db.id_of("dirt")
	id_stone = db.id_of("stone")
	id_sand = db.id_of("sand")
	id_coal = db.id_of("coal_ore")
	id_copper = db.id_of("copper_ore")
	id_iron = db.id_of("iron_ore")
	id_gold = db.id_of("gold_ore")
	id_bedrock = db.id_of("bedrock")
	_continent.seed = world_seed
	_continent.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_continent.frequency = 0.006
	_continent.fractal_octaves = 3
	_hills.seed = world_seed + 17
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_hills.frequency = 0.035
	_hills.fractal_octaves = 3
	_detail.seed = world_seed + 43
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail.frequency = 0.09
	_height_cache.clear()


## 0 = 蓝队区，1 = 中立区，2 = 红队区
func zone_of(x: int) -> int:
	if x < ZONE_A_END:
		return 0
	if x < ZONE_B_START:
		return 1
	return 2


## 中立区：地形与材质都和两侧一样，只是不能建造/破坏
func is_neutral(x: int) -> bool:
	return x >= ZONE_A_END and x < ZONE_B_START


## 地表高度（方块坐标，返回该列最高实心方块所在 y）
func height_at(x: int, z: int) -> int:
	var key := Vector2i(x, z)
	var cached = _height_cache.get(key, null)
	if cached != null:
		return cached
	var c := _continent.get_noise_2d(float(x), float(z))
	var hills := _hills.get_noise_2d(float(x), float(z)) * HILL_AMP
	var detail := _detail.get_noise_2d(float(x), float(z)) * DETAIL_AMP
	var h := int(round(float(BASE_HEIGHT) + c * 10.0 + hills + detail))
	var value := clampi(h, 3, 60)
	_height_cache[key] = value
	return value


func base_block(x: int, y: int, z: int) -> int:
	return block_at_height(x, y, z, height_at(x, z))


## 已算出该列高度 h 时的方块（避免重复查高度缓存）
func block_at_height(x: int, y: int, z: int, h: int) -> int:
	if y > h:
		return id_air
	if y <= 0:
		return id_bedrock
	if y == h:
		return id_sand if h <= 20 else id_grass
	if y >= h - 3:
		return id_dirt
	if y == h - 4 and h <= 20:
		return id_sand
	var roll := _hash01(x, y, z)
	if roll < 0.060:
		return id_coal
	if y <= h - 6 and roll < 0.100:
		return id_copper
	# 铁矿更深一些，金矿最深也最少
	if id_iron != 0 and y <= h - 10 and roll < 0.130:
		return id_iron
	if id_gold != 0 and y <= h - 16 and roll < 0.150:
		return id_gold
	return id_stone


func _hash01(x: int, y: int, z: int) -> float:
	var h: int = (x * 73856093) ^ (y * 19349663) ^ (z * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0
