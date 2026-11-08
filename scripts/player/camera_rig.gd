extends Node3D
## 自由飞行相机：鼠标常显，按住左键拖动转视角，WASD 移动。

signal primary_click(at: Vector2)
signal look_changed

@onready var camera: Camera3D = $Camera3D

var yaw := 0.0
var pitch := -0.25
var move_speed := 14.0
var fov := 70.0
var fast_multiplier := 3.0
var mouse_sensitivity := 0.0035
var dragging := false
## 打开 UI 面板时置 false：相机不再响应鼠标和键盘
var input_enabled := true

const MIN_SPEED := 1.0
const MAX_SPEED := 60.0
const DRAG_THRESHOLD := 4.0
## 滚轮缩放视野（度）
const FOV_MIN := 35.0
const FOV_MAX := 100.0
const FOV_STEP := 3.0

var _pressing := false
var _press_pos := Vector2.ZERO
## 拖动时把鼠标藏起来（捕获模式），松手后回到原来的位置
var _saved_mouse := Vector2.ZERO
## 鼠标压在 UI 面板上时置 true：滚轮不再调视野
var wheel_blocked := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if camera != null:
		camera.fov = fov


## 滚轮缩放视野
func zoom(step: float) -> void:
	fov = clampf(fov + step * FOV_STEP, FOV_MIN, FOV_MAX)
	if camera != null:
		camera.fov = fov


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if not wheel_blocked:
				zoom(-1.0)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not wheel_blocked:
				zoom(1.0)
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_pressing = true
				dragging = false
				_press_pos = event.position
				_saved_mouse = event.position
				# 拖动期间藏起鼠标并锁在窗口里，这样怎么拖都不会甩到屏幕外
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			elif _pressing:
				_pressing = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				if not dragging:
					primary_click.emit(_saved_mouse)
				else:
					# 转完视角把鼠标送回按下时的位置
					Input.warp_mouse(_saved_mouse)
				dragging = false
		return
	if event is InputEventMouseMotion and _pressing:
		if not dragging and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			dragging = true
		if dragging:
			yaw -= event.relative.x * mouse_sensitivity
			pitch = clampf(pitch - event.relative.y * mouse_sensitivity, -1.55, 1.55)
			look_changed.emit()


func _process(delta: float) -> void:
	rotation = Vector3(pitch, yaw, 0.0)
	if not input_enabled:
		return
	var dir := Vector3.ZERO
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	if Input.is_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_SHIFT):
		dir += Vector3.DOWN
	var speed := move_speed
	if Input.is_key_pressed(KEY_META):
		speed *= fast_multiplier
	if dir.length_squared() > 0.0:
		position += dir.normalized() * speed * delta


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		if _pressing:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_pressing = false
		dragging = false


func look_direction() -> Vector3:
	return -camera.global_basis.z
