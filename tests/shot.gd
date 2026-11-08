extends SceneTree
## 无头截图工具：渲染主场景 40 帧后保存为 docs/preview.png
var _frames := 0
var _scene: Node

func _initialize() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 40:
		var tex := root.get_viewport().get_texture()
		var img: Image = tex.get_image()
		if img != null:
			img.save_png("res://docs/preview.png")
			print("SHOT SAVED ", img.get_width(), "x", img.get_height())
		else:
			print("SHOT NULL")
		quit(0)
	return false
