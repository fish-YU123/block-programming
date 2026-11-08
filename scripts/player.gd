extends Node3D

const SidePanelUi = preload("res://scripts/side_panel.gd")

@export var move_speed := 28.0
@export var mouse_sensitivity := 0.15
@export var min_fov := 20.0
@export var max_fov := 110.0

var yaw := 0.0
var pitch := 32.0
var _drag_from_panel := false
var _press_pos := Vector2.ZERO
var _left_down := false
var _last_click_ms := 0
var _last_click_id := 0

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	camera.rotation_degrees.x = -pitch
	camera.fov = 70.0
	camera.near = 0.08
	camera.far = 320.0


func _panel() -> SidePanelUi:
	var node := get_parent().get_node_or_null("SidePanel")
	return node as SidePanelUi


func _input(event: InputEvent) -> void:
	var panel := _panel()
	var over := panel != null and panel.pointer_over()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_from_panel = over
			_left_down = not over
			_press_pos = event.position
		else:
			if _left_down and not over and event.position.distance_to(_press_pos) < 6.0:
				_click_world()
			_drag_from_panel = false
			_left_down = false
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if _drag_from_panel or over:
			return
		yaw -= event.relative.x * mouse_sensitivity
		pitch += event.relative.y * mouse_sensitivity
		pitch = clampf(pitch, -89.0, 89.0)
		rotation_degrees.y = yaw
		camera.rotation_degrees.x = -pitch
	elif event is InputEventMouseButton and event.pressed and not over:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.fov = clampf(camera.fov - 2.0, min_fov, max_fov)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.fov = clampf(camera.fov + 2.0, min_fov, max_fov)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_right_click_world(event.position)


func _unit_at_cursor() -> Node:
	var space := camera.get_world_3d().direct_space_state
	var mouse := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var to := from + camera.project_ray_normal(mouse) * 240.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 2)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	var node: Node = hit.collider as Node
	while node != null:
		if node.is_in_group("deployed_unit"):
			return node
		node = node.get_parent()
	return null


func _click_world() -> void:
	var panel := _panel()
	if panel == null:
		return
	if panel.block_edit_active():
		get_parent().call("paint_block", camera, panel.block_paint())
		return
	var unit := _unit_at_cursor()
	if unit == null:
		panel.stop_follow()
		panel._set_outline(null)
		_last_click_id = 0
		return
	var now := Time.get_ticks_msec()
	var uid := unit.get_instance_id()
	if uid == _last_click_id and now - _last_click_ms < 400:
		panel.focus_unit(unit, true)
		_last_click_id = 0
		_last_click_ms = 0
		return
	_last_click_id = uid
	_last_click_ms = now


func _right_click_world(at: Vector2) -> void:
	var panel := _panel()
	if panel == null:
		return
	var unit := _unit_at_cursor()
	if unit == null:
		return
	panel.offer_unit_save(unit, at)


func _apply_follow(target: Node3D) -> void:
	var point := target.global_position
	rotation_degrees.y = yaw
	camera.rotation_degrees.x = -pitch
	var looked = target.call("focus_point")
	if looked is Vector3:
		point = looked
	var look := -camera.global_basis.z
	if look.length_squared() < 0.0001:
		look = Vector3(0, -0.3, -1)
	global_position = point - look.normalized() * 14.0


func _process(delta: float) -> void:
	var panel := _panel()
	var world := get_parent()
	if panel != null and world != null:
		if panel.block_edit_active():
			world.call("aim_blocks", camera, bool(panel.block_paint().get("erase", false)))
		else:
			world.call("hide_block_aim")
	var lock_wasd := panel != null and panel.locks_move_keys()
	var north := -global_transform.basis.z
	north.y = 0.0
	if north.length_squared() < 0.0001:
		north = Vector3(0, 0, -1)
	north = north.normalized()
	var east := Vector3(-north.z, 0.0, north.x)
	var dir := Vector3.ZERO
	if not lock_wasd:
		if Input.is_key_pressed(KEY_W):
			dir += north
		if Input.is_key_pressed(KEY_S):
			dir -= north
		if Input.is_key_pressed(KEY_A):
			dir -= east
		if Input.is_key_pressed(KEY_D):
			dir += east
		if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
			dir.y += 1.0
		if Input.is_key_pressed(KEY_SHIFT):
			dir.y -= 1.0
	if dir != Vector3.ZERO:
		if panel != null:
			panel.stop_follow()
		global_position += dir.normalized() * move_speed * delta
		return
	if panel != null and panel.follow_target() != null:
		_apply_follow(panel.follow_target())
