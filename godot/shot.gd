extends SceneTree
## warmd shot for Godot: opens a scene with graphics, saves one frame, quits.

func _init() -> void:
	var scene := OS.get_environment("WARMD_SCENE")
	if scene == "":
		scene = ProjectSettings.get_setting("application/run/main_scene", "")
	if scene == "":
		printerr("error: no scene given and no main scene set")
		quit(1)
		return
	change_scene_to_file(scene)
	_capture.call_deferred()


func _capture() -> void:
	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(OS.get_environment("WARMD_SHOT"))
	quit(0 if err == OK else 1)
