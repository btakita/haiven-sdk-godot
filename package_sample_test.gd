# Runs the example scene from the cleanly installed addon archive.
extends SceneTree

const SAMPLE := "res://addons/haiven/examples/identity_modal_example.tscn"

var failures: Array[String] = []
var checks := 0


func check(what: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(what)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	check("the package exposes the example scene", ResourceLoader.exists(SAMPLE, "PackedScene"))
	var packed := load(SAMPLE) as PackedScene
	check("the example resource is a PackedScene", packed != null)
	var example := packed.instantiate()
	check("the example instantiates as a Control", example is Control)
	root.add_child(example)
	await process_frame

	var modal: Control = example.identity_modal
	var state: Dictionary = modal.view_state()
	check("the installed example opens the real packaged modal", modal != null and state["visible"])
	check("the installed example presents its MOTD", state["motd_visible"] and state["motd_title"] == "Haiven offline sample")
	var motd_panel: PanelContainer = example.motd_panel
	var motd_state: Dictionary = motd_panel.view_state()
	check("the example also instantiates the editor-authored MOTD panel",
		motd_panel != null and motd_panel.get_node("Content/Message/Title") is Label)
	check("the authored panel reaches the shared present state",
		motd_state["status"] == "present" and motd_state["visible"])
	check("the packaged Theme exposes designer seams",
		motd_panel.theme.get_type_variation_base(&"HaivenMotdTitle") == &"Label")
	check("the example starts without a linked provider", state["providers"]["apple"]["action"] == "Connect")
	check("the example clearly labels its offline boundary", "Offline sample" in _all_label_text(example))
	check("the installed example facade refreshes through the modal", (await modal.refresh()).get("ok"))

	var action := modal.find_child("MotdAction", true, false) as Button
	action.pressed.emit()
	check("the example handles MOTD navigation without leaving the editor", example.activity_text() == "MOTD action requested: https://docs.haiven.gg")

	var apple := modal.find_child("AppleAction", true, false) as Button
	apple.pressed.emit()
	await process_frame
	await process_frame
	state = modal.view_state()
	check("the offline facade drives the packaged modal's link event", state["providers"]["apple"]["detail"] == "apple@example.test")
	check("the linked sample offers disconnect", state["providers"]["apple"]["action"] == "Disconnect")

	apple.pressed.emit()
	await process_frame
	state = modal.view_state()
	check("the offline facade drives unlink through the packaged modal", state["providers"]["apple"]["action"] == "Connect")

	var close_button := modal.find_child("Close", true, false) as Button
	close_button.pressed.emit()
	check("the sample observes modal close", not modal.visible and example.activity_text() == "Closed the Haiven identity modal.")
	var open_button := example.find_child("OpenAccount", true, false) as Button
	open_button.pressed.emit()
	check("the sample launcher reopens the installed modal", modal.visible and example.activity_text() == "Opened the installed Haiven identity modal.")

	example.queue_free()
	if failures.is_empty():
		print("ok   packaged Godot example scene")
		print("HAIVEN_TEST_PASS package_sample %d" % checks)
		quit(0)
	else:
		for failure: String in failures:
			push_error(failure)
		print("FAIL packaged Godot example: %d/%d failed" % [failures.size(), checks])
		quit(1)


func _all_label_text(node: Node) -> String:
	var lines: Array[String] = []
	if node is Label:
		lines.append(node.text)
	for child: Node in node.get_children():
		lines.append(_all_label_text(child))
	return "\n".join(lines)
