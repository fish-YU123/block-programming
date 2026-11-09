extends SceneTree
## 生成 docs/preview-loading.png：世界生成中的加载提示

var _f := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_f += 1
	if _f == 45 and not _main._world_ready:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-loading.png")
		print("SAVED")
		quit(0)
	if _main._world_ready:
		print("太早就绪了，跳过")
		quit(0)
	return false
