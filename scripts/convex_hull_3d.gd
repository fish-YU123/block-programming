extends RefCounted
class_name ConvexHull3D

## 点集 → 三角面顶点流（每 3 个一点，绕序朝外）。点数很少时用穷举即可。


static func build(points: PackedVector3Array) -> PackedVector3Array:
	var uniq := _unique(points)
	var n := uniq.size()
	var out := PackedVector3Array()
	if n < 3:
		return out
	if n == 3:
		var a := uniq[0]
		var b := uniq[1]
		var c := uniq[2]
		if (b - a).cross(c - a).length_squared() < 1e-12:
			return out
		out.append(a)
		out.append(b)
		out.append(c)
		out.append(a)
		out.append(c)
		out.append(b)
		return out
	var center := Vector3.ZERO
	for p in uniq:
		center += p
	center /= float(n)
	var face_keys := {}
	for i in n:
		for j in range(i + 1, n):
			for k in range(j + 1, n):
				var a: Vector3 = uniq[i]
				var b: Vector3 = uniq[j]
				var c: Vector3 = uniq[k]
				var nrm: Vector3 = (b - a).cross(c - a)
				if nrm.length_squared() < 1e-12:
					continue
				var pos := 0
				var neg := 0
				for t in n:
					if t == i or t == j or t == k:
						continue
					var side: float = nrm.dot(uniq[t] - a)
					if side > 1e-6:
						pos += 1
					elif side < -1e-6:
						neg += 1
				if pos > 0 and neg > 0:
					continue
				# 全体在一侧（或共面）：取朝外
				if nrm.dot(center - a) > 0.0:
					var tmp := b
					b = c
					c = tmp
					nrm = -nrm
				var key := _face_key(a, b, c)
				if face_keys.has(key):
					continue
				face_keys[key] = true
				out.append(a)
				out.append(b)
				out.append(c)
	return out


static func _unique(points: PackedVector3Array) -> PackedVector3Array:
	var seen := {}
	var out := PackedVector3Array()
	for p in points:
		var k := "%.5f,%.5f,%.5f" % [p.x, p.y, p.z]
		if seen.has(k):
			continue
		seen[k] = true
		out.append(p)
	return out


static func _face_key(a: Vector3, b: Vector3, c: Vector3) -> String:
	var keys: Array[String] = [
		"%.5f,%.5f,%.5f" % [a.x, a.y, a.z],
		"%.5f,%.5f,%.5f" % [b.x, b.y, b.z],
		"%.5f,%.5f,%.5f" % [c.x, c.y, c.z],
	]
	keys.sort()
	return ",".join(keys)
