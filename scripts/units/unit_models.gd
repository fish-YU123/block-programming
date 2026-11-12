extends RefCounted
## 每种单位各自的 3D 造型。
## 所有尺寸都以「0.75 米基准单位」为单位，外部用 k = unit_size / 0.75 整体缩放。
## 约定：动画需要的部件用固定名字挂出来（Flame / Radar / Barrel / RCS0..N / Drill）。
## 零外部素材，全部用 BoxMesh / CylinderMesh / SphereMesh / TorusMesh / PrismMesh 拼。

const MatCache = preload("res://scripts/core/mat_cache.gd")


static func is_custom(unit_id: String) -> bool:
	return unit_id in ["builder", "scout", "cargo", "gunship", "kamikaze", "repair", "jammer", "burrower", "carrier"]


static func build(unit_id: String, team: int) -> Node3D:
	var model := Node3D.new()
	model.name = "Model"
	var body_color := Color(0.16, 0.28, 0.62) if team == 0 else Color(0.62, 0.15, 0.14)
	var trim_color := Color(0.28, 0.85, 0.95) if team == 0 else Color(0.98, 0.62, 0.18)
	var body: StandardMaterial3D = MatCache.solid("u_body_%s_%d" % [unit_id, team], body_color)
	var trim: StandardMaterial3D = MatCache.solid("u_trim_%s_%d" % [unit_id, team], trim_color)
	var dark: StandardMaterial3D = MatCache.solid("u_dark", Color(0.18, 0.19, 0.22))
	var metal: StandardMaterial3D = MatCache.solid("u_metal", Color(0.55, 0.58, 0.62))
	var warm: StandardMaterial3D = MatCache.solid("u_warm", Color(0.95, 0.55, 0.18), false, 0.4)
	var glow: StandardMaterial3D = MatCache.of(trim_color, true, 0.8)
	var red: StandardMaterial3D = MatCache.solid("u_warhead", Color(0.85, 0.2, 0.16), false, 0.3)

	match unit_id:
		"builder":
			_box(model, body, Vector3(0.6, 0.22, 0.58), Vector3.ZERO)
			_box(model, warm, Vector3(0.34, 0.1, 0.4), Vector3(0, 0.16, 0))
			# 两条机械臂 + 吊钩
			for sx: float in [-1.0, 1.0]:
				var arm := _cylinder(model, metal, 0.045, 0.5, Vector3(sx * 0.3, -0.02, -0.12), Vector3(-PI * 0.5, 0, 0))
				arm.name = "Arm%d" % int(sx)
				_box(model, warm, Vector3(0.1, 0.1, 0.12), Vector3(sx * 0.3, -0.02, -0.4))
			_cylinder(model, dark, 0.02, 0.5, Vector3(0, 0.28, 0.1))
			_dome(model, glow, 0.06, Vector3(0, 0.3, 0.1))
			_jet(model, trim, Vector3(0, -0.14, 0.18), 0.8)
		"scout":
			# 细长梭形：机身 + 后掠翼 + 大天线
			_box(model, body, Vector3(0.22, 0.16, 0.86), Vector3.ZERO)
			_prism(model, trim, Vector3(0.7, 0.03, 0.24), Vector3(0, 0.02, 0.06))
			_dome(model, glow, 0.12, Vector3(0, 0.16, 0.22))
			_cylinder(model, metal, 0.008, 0.34, Vector3(0, 0.3, 0.22))
			_box(model, trim, Vector3(0.04, 0.04, 0.16), Vector3(0, 0.1, -0.4))
			_jet(model, trim, Vector3(0, -0.1, 0.34), 0.7)
		"cargo":
			# 大货箱 + 四角吊架
			_box(model, body, Vector3(0.66, 0.18, 0.66), Vector3.ZERO)
			_box(model, dark, Vector3(0.5, 0.34, 0.5), Vector3(0, -0.26, 0))
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					_cylinder(model, metal, 0.025, 0.22, Vector3(sx * 0.3, -0.14, sz * 0.3))
					_jet(model, trim, Vector3(sx * 0.3, -0.24, sz * 0.3), 0.45)
			_dome(model, glow, 0.09, Vector3(0, 0.16, 0.18))
		"gunship":
			# 宽机身 + 双炮管 + 装甲片
			_box(model, body, Vector3(0.86, 0.26, 0.9), Vector3.ZERO)
			_box(model, dark, Vector3(0.7, 0.1, 0.5), Vector3(0, 0.18, 0))
			for sx: float in [-1.0, 1.0]:
				var barrel := _cylinder(model, metal, 0.05, 0.5, Vector3(sx * 0.22, -0.04, -0.62), Vector3(-PI * 0.5, 0, 0))
				if sx > 0.0:
					barrel.name = "Barrel"
			_dome(model, glow, 0.1, Vector3(0, 0.24, 0.2))
			for sx: float in [-1.0, 1.0]:
				_jet(model, trim, Vector3(sx * 0.3, -0.16, 0.3), 1.0)
		"kamikaze":
			# 弹头锥 + 尾翼
			_cylinder(model, body, 0.14, 0.34, Vector3.ZERO)
			_cone(model, red, 0.16, 0.4, Vector3(0, -0.02, -0.34), Vector3(-PI * 0.5, 0, 0))
			for i in 4:
				var fin := _box(model, trim, Vector3(0.3, 0.02, 0.16), Vector3(0, 0, 0.16))
				fin.rotation = Vector3(0, float(i) * PI * 0.5, 0)
			_jet(model, warm, Vector3(0, 0, 0.26), 1.0)
		"repair":
			# 机身 + 两侧机械臂 + 顶部十字
			_box(model, body, Vector3(0.56, 0.18, 0.56), Vector3.ZERO)
			for sx: float in [-1.0, 1.0]:
				_box(model, metal, Vector3(0.08, 0.08, 0.34), Vector3(sx * 0.32, -0.04, -0.1))
				_box(model, glow, Vector3(0.1, 0.1, 0.06), Vector3(sx * 0.32, -0.04, -0.28))
			_box(model, glow, Vector3(0.28, 0.05, 0.05), Vector3(0, 0.2, 0))
			_box(model, glow, Vector3(0.05, 0.05, 0.28), Vector3(0, 0.2, 0))
			_jet(model, trim, Vector3(0, -0.14, 0.16), 0.7)
		"jammer":
			# 机身 + 三层旋转环 + 长天线
			_box(model, body, Vector3(0.5, 0.18, 0.5), Vector3.ZERO)
			for i in 3:
				var ring := MeshInstance3D.new()
				var torus := TorusMesh.new()
				torus.inner_radius = 0.16 + 0.06 * float(i)
				torus.outer_radius = 0.2 + 0.06 * float(i)
				ring.mesh = torus
				ring.material_override = glow
				ring.position = Vector3(0, 0.1 + float(i) * 0.14, 0)
				model.add_child(ring)
				if i == 2:
					ring.name = "Radar"
			_cylinder(model, metal, 0.012, 0.3, Vector3(0, 0.34, 0))
			_jet(model, trim, Vector3(0, -0.14, 0.16), 0.7)
		"burrower":
			# 短机身 + 超大钻头锥
			_box(model, body, Vector3(0.62, 0.26, 0.52), Vector3.ZERO)
			var drill := _cone(model, metal, 0.2, 0.62, Vector3(0, -0.02, -0.5), Vector3(-PI * 0.5, 0, 0))
			drill.name = "Drill"
			_ring(model, warm, 0.2, 0.02, Vector3(0, -0.02, -0.24))
			_dome(model, glow, 0.08, Vector3(0, 0.2, 0.1))
			for sx: float in [-1.0, 1.0]:
				_jet(model, trim, Vector3(sx * 0.24, -0.18, 0.2), 0.9)
		"carrier":
			# 大平板 + 四条腿 + 中央雷达
			_box(model, body, Vector3(1.0, 0.14, 1.0), Vector3.ZERO)
			_box(model, dark, Vector3(0.7, 0.1, 0.7), Vector3(0, 0.12, 0))
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					_cylinder(model, metal, 0.035, 0.3, Vector3(sx * 0.4, -0.2, sz * 0.4))
					_jet(model, trim, Vector3(sx * 0.4, -0.3, sz * 0.4), 0.5)
			_dome(model, glow, 0.22, Vector3(0, 0.24, 0))
		_:
			_box(model, body, Vector3(0.62, 0.2, 0.62), Vector3.ZERO)

	return model


# ---------------- 建模小工具 ----------------

static func _box(parent: Node3D, mat: Material, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _cylinder(parent: Node3D, mat: Material, radius: float, height: float, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _cone(parent: Node3D, mat: Material, radius: float, height: float, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.01
	mesh.bottom_radius = radius
	mesh.height = height
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _dome(parent: Node3D, mat: Material, radius: float, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _prism(parent: Node3D, mat: Material, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := PrismMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _ring(parent: Node3D, mat: Material, radius: float, thickness: float, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - thickness
	mesh.outer_radius = radius + thickness
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _jet(parent: Node3D, mat: Material, pos: Vector3, scale_y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.02
	mesh.bottom_radius = 0.08
	mesh.height = 0.26
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = Vector3(1.0, scale_y, 1.0)
	mi.name = "Flame"
	parent.add_child(mi)
	return mi
