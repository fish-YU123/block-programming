extends SceneTree
## 导出程序生成的方块贴图图集：docs/preview-atlas.png（放大 6 倍便于查看）

func _initialize() -> void:
	var DB = load("res://scripts/world/block_db.gd")
	var Atlas = load("res://scripts/world/texture_atlas.gd")
	var db = DB.new()
	db.load_dir("res://data/blocks")
	var atlas = Atlas.new()
	atlas.build(db)
	# 图集本身 128×128（8×8 格，每格 16×16，每方块 3 格：顶/底/侧）
	var img: Image = atlas.image.duplicate()
	img.resize(img.get_width() * 6, img.get_height() * 6, Image.INTERPOLATE_NEAREST)
	img.save_png("res://docs/preview-atlas.png")
	print("SAVED %dx%d" % [img.get_width(), img.get_height()])
	quit(0)
