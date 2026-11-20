# In-engine shared-state and authored-scene coverage for HaivenMotdPanel.
extends SceneTree

const PANEL := "res://addons/haiven/haiven_motd_panel.tscn"
const CONTRACT := "res://motd-v1.json"
const MotdProjection := preload("res://addons/haiven/haiven_motd_projection.gd")


class FakeIdentity:
	extends RefCounted

	signal motd_changed(message: Variant)
	signal load_released

	var current_motd: Variant = null
	var load_result: Dictionary = {"ok": true, "motd": null}
	var suspend_load := false
	var load_calls := 0
	var dismiss_calls := 0

	func load_motd() -> Dictionary:
		load_calls += 1
		if suspend_load:
			suspend_load = false
			await load_released
		return load_result.duplicate(true)

	func dismiss_motd() -> void:
		dismiss_calls += 1
		current_motd = null
		motd_changed.emit(null)

	func realtime(message: Variant) -> void:
		current_motd = message.duplicate(true) if message is Dictionary else null
		motd_changed.emit(current_motd)


var failures: Array[String] = []
var checks := 0


func check(what: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(what)


func _initialize() -> void:
	call_deferred("_run")


func motd(message_id: String, title := "Welcome", url := "https://news.haiven.gg/update") -> Dictionary:
	return {
		"id": message_id,
		"title": title,
		"body": "[b]Plain text[/b] launch notice.",
		"url": url,
	}


func fixture_model(fixture: Dictionary, by_id: Dictionary) -> RefCounted:
	var initial: Variant = fixture.get("initial")
	if initial is Dictionary:
		return MotdProjection.new(initial)
	var reference := String(fixture.get("initial_fixture", ""))
	if not by_id.has(reference):
		return MotdProjection.new()
	var referenced: Dictionary = by_id[reference]
	var model := fixture_model(referenced, by_id)
	for step: Dictionary in referenced.get("steps", []):
		model.apply(step.get("input", {}))
	return model


func projections_equal(actual: Dictionary, expected: Dictionary) -> bool:
	var normalized_actual := actual.duplicate(true)
	var normalized_expected := expected.duplicate(true)
	normalized_actual["revision"] = int(normalized_actual.get("revision", -1))
	normalized_expected["revision"] = int(normalized_expected.get("revision", -1))
	return normalized_actual == normalized_expected


func run_contract_fixtures(contract: Dictionary, fixture_failures: Array[String]) -> bool:
	var fixture_list: Array = contract.get("fixtures", [])
	var by_id: Dictionary = {}
	for fixture: Dictionary in fixture_list:
		by_id[String(fixture.get("id", ""))] = fixture
	for fixture: Dictionary in fixture_list:
		var fixture_id := String(fixture.get("id", ""))
		var model := fixture_model(fixture, by_id)
		for step: Dictionary in fixture.get("steps", []):
			var actual: Dictionary = model.apply(step.get("input", {}))
			var expected: Variant = step.get("expect")
			if not expected is Dictionary or not projections_equal(actual, expected):
				fixture_failures.append("%s transition mismatch: %s != %s" % [fixture_id, actual, expected])
	return fixture_failures.is_empty() and by_id.size() == 11


func _run() -> void:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT))
	check("the canonical contract and fixture set are loaded",
		contract.get("id") == "haiven.presentation.motd/v1" and contract.get("fixture_set") == "motd-display-v1")
	var fixture_failures: Array[String] = []
	check("all 11 canonical transition vectors execute against the shipped model",
		run_contract_fixtures(contract, fixture_failures))
	failures.append_array(fixture_failures)
	var suppressed_during_load := MotdProjection.new()
	var suppressed_message := motd("00000000-0000-4000-8000-000000000010", "Dismissed")
	suppressed_during_load.apply({"type": "realtime_present", "message": suppressed_message})
	suppressed_during_load.apply({"type": "dismiss"})
	suppressed_during_load.apply({"type": "load_started", "requestId": "pending-after-dismiss"})
	suppressed_during_load.apply({"type": "realtime_present", "message": suppressed_message})
	var accepted_after_suppression := suppressed_during_load.apply({
		"type": "rest_present",
		"requestId": "pending-after-dismiss",
		"message": motd("00000000-0000-4000-8000-000000000011", "Fresh"),
	})
	check("a suppressed realtime no-op does not cancel the active REST request",
		accepted_after_suppression["status"] == "present"
		and accepted_after_suppression["message"]["id"] == "00000000-0000-4000-8000-000000000011")

	var panel := (load(PANEL) as PackedScene).instantiate()
	root.add_child(panel)
	await process_frame
	check("the packaged surface is an editor-authored panel", panel is PanelContainer)
	check("title and body are plain-text Label controls",
		panel.get_node("Content/Message/Title") is Label and panel.get_node("Content/Message/Body") is Label)
	check("the scene exposes semantic Theme variations",
		panel.theme.get_type_variation_base(&"HaivenMotdPanel") == &"PanelContainer"
		and panel.theme.get_type_variation_base(&"HaivenMotdTitle") == &"Label"
		and panel.theme.get_type_variation_base(&"HaivenMotdPrimaryAction") == &"Button")
	var identity := FakeIdentity.new()
	check("a complete identity facade binds", panel.bind(identity).get("ok"))
	var initial: Dictionary = panel.view_state()
	check("the normalized initial state is absent", initial == {
		"revision": 0,
		"status": "absent",
		"visible": false,
		"message": null,
		"error": null,
		"dismissedId": null,
	})

	identity.suspend_load = true
	identity.load_result = {"ok": true, "motd": null}
	panel.load_public()
	await process_frame
	var loading: Dictionary = panel.view_state()
	check("the public MOTD starts before any token gate", identity.load_calls == 1 and loading["status"] == "loading")
	check("loading is visible and has a finite revision", loading["visible"] and loading["revision"] == 1)
	identity.load_released.emit()
	await process_frame
	var absent: Dictionary = panel.view_state()
	check("a no-content result becomes absent", absent["status"] == "absent" and not absent["visible"])
	var absent_revision := int(absent["revision"])
	identity.realtime(null)
	check("a duplicate absent state does not advance revision", panel.view_state()["revision"] == absent_revision)

	var first := motd("00000000-0000-4000-8000-000000000001", "")
	identity.load_result = {"ok": true, "motd": first}
	var loaded: Dictionary = await panel.load_public()
	var present: Dictionary = panel.view_state()
	check("a successful result becomes present", loaded["ok"] and present["status"] == "present" and present["visible"])
	check("the projection uses the shared fallback title", present["message"]["title"] == "Message of the day")
	check("the projection contains presentation fields only",
		present["message"].keys() == ["id", "title", "body", "url"])
	check("markup-like body content stays literal plain text",
		panel.get_node("Content/Message/Body").text == "[b]Plain text[/b] launch notice.")
	var present_revision := int(present["revision"])
	identity.realtime(first)
	check("a duplicate current message does not advance revision", panel.view_state()["revision"] == present_revision)

	var requested: Array[String] = []
	panel.action_requested.connect(func(url: String) -> void: requested.append(url))
	panel.get_node("Content/Message/Actions/Action").pressed.emit()
	check("safe HTTPS navigation is delegated to the host", requested == ["https://news.haiven.gg/update"])
	panel.get_node("Content/Message/Actions/Dismiss").pressed.emit()
	var dismissed: Dictionary = panel.view_state()
	check("dismiss records the id and hides the message",
		dismissed["status"] == "absent" and not dismissed["visible"]
		and dismissed["dismissedId"] == first["id"] and identity.dismiss_calls == 1)
	var dismissed_revision := int(dismissed["revision"])
	identity.realtime(first)
	check("the same id stays suppressed for the session", panel.view_state()["revision"] == dismissed_revision)
	var second := motd("00000000-0000-4000-8000-000000000002", "New notice")
	identity.realtime(second)
	check("a new id reappears", panel.view_state()["status"] == "present" and panel.view_state()["message"]["id"] == second["id"])

	var unsafe := motd("00000000-0000-4000-8000-000000000003", "Unsafe action", "http://example.test")
	identity.realtime(unsafe)
	var unsafe_state: Dictionary = panel.view_state()
	check("non-HTTPS actions are omitted without hiding the notice", unsafe_state["status"] == "present" and not unsafe_state["message"].has("url"))
	panel.get_node("Content/Message/Actions/Action").pressed.emit()
	check("an omitted action cannot reach the host", requested.size() == 1)

	identity.load_result = {"ok": false, "error": "transport_secret_detail"}
	var failed: Dictionary = await panel.load_public()
	var failure: Dictionary = panel.view_state()
	check("a failed public read reaches failure", not failed["ok"] and failure["status"] == "failure" and failure["visible"])
	check("failure copy is bounded and transport-agnostic",
		failure["error"] == "Unable to load message of the day."
		and not String(failure["error"]).contains("transport_secret_detail")
		and panel.get_node("Content/Retry").visible)
	identity.realtime(null)
	var cleared: Dictionary = panel.view_state()
	check("realtime clear hides content while retaining the dismissed id",
		cleared["status"] == "absent" and not cleared["visible"] and cleared["message"] == null
		and cleared["dismissedId"] == first["id"])

	identity.suspend_load = true
	identity.load_result = {"ok": true, "motd": first}
	panel.load_public()
	await process_frame
	var realtime := motd("00000000-0000-4000-8000-000000000004", "Realtime wins")
	identity.realtime(realtime)
	var realtime_revision := int(panel.view_state()["revision"])
	identity.load_released.emit()
	await process_frame
	var after_stale: Dictionary = panel.view_state()
	check("a newer realtime message wins over stale REST completion",
		after_stale["status"] == "present" and after_stale["message"]["id"] == realtime["id"]
		and after_stale["revision"] == realtime_revision)

	panel.queue_free()
	if failures.is_empty():
		print("HAIVEN_TEST_PASS motd_presentation %d" % checks)
		print("MOTD_FIXTURE_PASS motd-display-v1 11")
		quit(0)
	else:
		for failure_name: String in failures:
			push_error(failure_name)
		print("HAIVEN_TEST_FAIL motd_presentation %d/%d" % [failures.size(), checks])
		quit(1)
