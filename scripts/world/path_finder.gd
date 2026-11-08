extends RefCounted
## 体素世界里的 A* 寻路（3D，26 邻域）
##
## 只认「空气格」可走：方块挡住就绕。单位飞行时用这个算出折线航路，
## 再由 flyer 的自动驾驶跟随，所以不会一头撞进山体。
##
## 用法：
##   var path: Array = PathFinder.find_path(world, 起点世界坐标, 终点世界坐标)
## 返回一串世界坐标（格心），不含起点、以终点结束；找不到返回空数组。

## 单个格子最多扩展多少节点（防止一次搜索卡住一帧）
const MAX_NODES_DEFAULT := 4000
## 搜索范围在起终点包围盒外扩多少格
const PAD_DEFAULT := 18
## 略高于地面飞行时，允许穿过离地这么近的格子也走
const MIN_Y := 1

## 26 邻域方向（含代价）
static func _dirs() -> Array:
	var list: Array = []
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var v := Vector3i(dx, dy, dz)
				list.append({"v": v, "cost": sqrt(float(dx * dx + dy * dy + dz * dz))})
	return list


static func cell_center(cell: Vector3i) -> Vector3:
	return Vector3(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)


## 起终点之间是否一条直线无遮挡（步长 0.4 格采样）
static func line_clear(world: Node, from: Vector3, to: Vector3) -> bool:
	var delta := to - from
	var length := delta.length()
	if length < 0.001:
		return true
	var steps := int(ceil(length / 0.4))
	for i in range(1, steps + 1):
		var p := from + delta * (float(i) / float(steps))
		var cell := Vector3i(floori(p.x), floori(p.y), floori(p.z))
		if world.is_solid(cell):
			return false
	return true


## 找一条从 from 到 to 的航路；返回世界坐标数组（不含起点）
static func find_path(world: Node, from: Vector3, to: Vector3, max_nodes := MAX_NODES_DEFAULT, pad := PAD_DEFAULT) -> Array:
	var start := Vector3i(floori(from.x), floori(from.y), floori(from.z))
	var goal := Vector3i(floori(to.x), floori(to.y), floori(to.z))
	if start == goal:
		return [cell_center(goal)]
	# 目标在方块里就往上抬到空气
	var lifted := 0
	while world.is_solid(goal) and lifted < 6:
		goal.y += 1
		lifted += 1
	if world.is_solid(goal):
		return []
	if world.is_solid(start):
		start.y += 1
	# 直线可达就直接走
	if line_clear(world, cell_center(start), cell_center(goal)):
		return [_clamp_to_world(world, goal)]

	var x0: int = mini(start.x, goal.x) - pad
	var x1: int = maxi(start.x, goal.x) + pad
	var y0: int = maxi(MIN_Y, mini(start.y, goal.y) - pad)
	var y1: int = mini(world.size_y - 1, maxi(start.y, goal.y) + pad)
	var z0: int = mini(start.z, goal.z) - pad
	var z1: int = maxi(start.z, goal.z) + pad
	var sx := x1 - x0 + 1
	var sy := y1 - y0 + 1
	var sz := z1 - z0 + 1
	if sx <= 0 or sy <= 0 or sz <= 0:
		return []

	var total := sx * sy * sz
	var g_score := PackedFloat32Array()
	g_score.resize(total)
	g_score.fill(INF)
	var came := PackedInt32Array()
	came.resize(total)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(total)
	closed.fill(0)

	var start_idx := _idx(start, x0, y0, z0, sx, sy)
	var goal_idx := _idx(goal, x0, y0, z0, sx, sy)
	if start_idx < 0 or goal_idx < 0:
		return []

	# 开集：按 f 排序的小顶堆（存 [f, idx]）
	var open: Array = []
	var dirs := _dirs()
	g_score[start_idx] = 0.0
	open.append([_heuristic(start, goal), 0, start_idx])
	var expanded := 0
	var reached := false
	while not open.is_empty() and expanded < max_nodes:
		var current: Array = _pop(open)
		var idx: int = current[2]
		if closed[idx] == 1:
			continue
		closed[idx] = 1
		expanded += 1
		if idx == goal_idx:
			reached = true
			break
		var cell := _cell_of(idx, x0, y0, z0, sx, sy)
		var base_g: float = g_score[idx]
		for d in dirs:
			var v: Vector3i = d["v"]
			var next := cell + v
			if next.x < x0 or next.x > x1 or next.y < y0 or next.y > y1 or next.z < z0 or next.z > z1:
				continue
			if not _passable(world, cell, v):
				continue
			var nidx := _idx(next, x0, y0, z0, sx, sy)
			if nidx < 0 or closed[nidx] == 1:
				continue
			var tentative: float = base_g + float(d["cost"])
			if tentative < g_score[nidx]:
				g_score[nidx] = tentative
				came[nidx] = idx
				var f := tentative + _heuristic(next, goal)
				_open_push(open, [f, -tentative, nidx])
	if not reached:
		return []
	# 回溯
	var cells: Array = []
	var cur := goal_idx
	while cur != -1 and cur != start_idx:
		cells.append(_cell_of(cur, x0, y0, z0, sx, sy))
		cur = came[cur]
	cells.reverse()
	# 抽稀：能直连的中间点全部去掉
	return _smooth(world, start, cells)


## 沿路径抽稀：从当前点往后找最远一个可以直连的点
static func _smooth(world: Node, start: Vector3, cells: Array) -> Array:
	var points: Array = []
	for c in cells:
		points.append(cell_center(c))
	if points.is_empty():
		return []
	var result: Array = []
	var anchor := start
	var i := 0
	while i < points.size():
		var best := i
		var j := points.size() - 1
		while j > i:
			if line_clear(world, anchor, points[j]):
				best = j
				break
			j -= 1
		result.append(points[best])
		anchor = points[best]
		i = best + 1
	return result


static func _passable(world: Node, cell: Vector3i, move: Vector3i) -> bool:
	var next := cell + move
	if world.is_solid(next):
		return false
	# 斜着走时，两条相邻的直边也要是空的，避免"从方块角里穿过去"
	if move.x != 0 and move.y != 0:
		if world.is_solid(cell + Vector3i(move.x, 0, 0)) and world.is_solid(cell + Vector3i(0, move.y, 0)):
			return false
	if move.x != 0 and move.z != 0:
		if world.is_solid(cell + Vector3i(move.x, 0, 0)) and world.is_solid(cell + Vector3i(0, 0, move.z)):
			return false
	if move.y != 0 and move.z != 0:
		if world.is_solid(cell + Vector3i(0, move.y, 0)) and world.is_solid(cell + Vector3i(0, 0, move.z)):
			return false
	return true


static func _clamp_to_world(world: Node, cell: Vector3i) -> Vector3:
	var y: int = clampi(cell.y, 0, world.size_y - 1)
	return cell_center(Vector3i(cell.x, y, cell.z))


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	var dx := float(a.x - b.x)
	var dy := float(a.y - b.y)
	var dz := float(a.z - b.z)
	return sqrt(dx * dx + dy * dy + dz * dz)


static func _idx(cell: Vector3i, x0: int, y0: int, z0: int, sx: int, sy: int) -> int:
	var lx := cell.x - x0
	var ly := cell.y - y0
	var lz := cell.z - z0
	if lx < 0 or ly < 0 or lz < 0:
		return -1
	return lx + ly * sx + lz * sx * sy


static func _cell_of(idx: int, x0: int, y0: int, z0: int, sx: int, sy: int) -> Vector3i:
	var lx := idx % sx
	var rest := (idx - lx) / sx
	var ly := rest % sy
	var lz := (rest - ly) / sy
	return Vector3i(x0 + lx, y0 + ly, z0 + lz)


## 小顶堆（数组实现，元素是 [f, 次序, idx]）
static func _open_push(open: Array, item: Array) -> void:
	open.append(item)
	var i := open.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if _less(open[i], open[parent]):
			var tmp = open[i]
			open[i] = open[parent]
			open[parent] = tmp
			i = parent
		else:
			break


static func _pop(open: Array) -> Array:
	var top: Array = open[0]
	var last: Array = open.pop_back()
	if not open.is_empty():
		open[0] = last
		var i := 0
		var n := open.size()
		while true:
			var left := i * 2 + 1
			var right := left + 1
			var smallest := i
			if left < n and _less(open[left], open[smallest]):
				smallest = left
			if right < n and _less(open[right], open[smallest]):
				smallest = right
			if smallest == i:
				break
			var tmp = open[i]
			open[i] = open[smallest]
			open[smallest] = tmp
			i = smallest
	return top


static func _less(a: Array, b: Array) -> bool:
	if float(a[0]) != float(b[0]):
		return float(a[0]) < float(b[0])
	return int(a[1]) < int(b[1])
