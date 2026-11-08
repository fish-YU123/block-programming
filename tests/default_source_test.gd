extends SceneTree
const SidePanelScript = preload("res://scripts/side_panel.gd")
const VM = preload("res://scripts/lang/py_vm.gd")
func _initialize() -> void:
	var vm := VM.new()
	vm.load_source(SidePanelScript.DEFAULT_SOURCE)
	print("error=", vm.error)
	quit(0)
