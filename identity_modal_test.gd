# In-engine coverage for the packaged account-linking and MOTD modal.
extends SceneTree

const IdentityModal := preload("res://addons/haiven/haiven_identity_modal.gd")


class FakeIdentity:
	extends RefCounted

	signal motd_changed(message: Variant)
	signal sign_in_methods_changed(methods: Dictionary)
	signal identity_linked(identity: Dictionary)
	signal identity_link_failed(failure: Dictionary)
	signal link_released(response: Dictionary)
	signal unlink_released(response: Dictionary)

	var current_motd: Variant = {
		"id": "00000000-0000-4000-8000-000000000001",
		"title": "Season update",
		"body": "New rewards are live.",
		"url": "https://news.haiven.gg/season",
		"startsAt": "2026-10-14T00:00:00Z",
	}
	var current_sign_in_methods := {
		"hasPassword": true,
		"identities": [{"provider": "google", "email": "player@example.test"}],
	}
	var link_response := {"ok": true, "provider": "apple"}
	var unlink_response := {"ok": true, "provider": "google"}
	var suspend_link := false
	var suspend_unlink := false
	var link_calls: Array[String] = []
	var unlink_calls: Array[String] = []
	var motd_loads := 0
	var method_loads := 0
	var dismissals := 0

	func begin_link(provider: String) -> Dictionary:
		link_calls.append(provider)
		if suspend_link:
			suspend_link = false
			var released: Dictionary = await link_released
			return released
		return link_response.duplicate(true)

	func unlink(provider: String) -> Dictionary:
		unlink_calls.append(provider)
		var response: Dictionary = unlink_response.duplicate(true)
		if suspend_unlink:
			suspend_unlink = false
			response = await unlink_released
		if bool(response.get("ok", false)):
			var kept: Array = []
			for identity: Dictionary in current_sign_in_methods["identities"]:
				if identity["provider"] != provider:
					kept.append(identity.duplicate(true))
			current_sign_in_methods["identities"] = kept
			sign_in_methods_changed.emit(current_sign_in_methods.duplicate(true))
		return response

	func dismiss_motd() -> void:
		dismissals += 1
		current_motd = null
		motd_changed.emit(null)

	func load_motd() -> Dictionary:
		motd_loads += 1
		motd_changed.emit(current_motd.duplicate(true) if current_motd is Dictionary else null)
		return {"ok": true, "motd": current_motd}

	func load_sign_in_methods() -> Dictionary:
		method_loads += 1
		sign_in_methods_changed.emit(current_sign_in_methods.duplicate(true))
		return {"ok": true, "methods": current_sign_in_methods.duplicate(true)}

	func complete_link(provider: String, email: String) -> void:
		var identity := {"provider": provider, "email": email}
		current_sign_in_methods["identities"].append(identity.duplicate(true))
		sign_in_methods_changed.emit(current_sign_in_methods.duplicate(true))
		identity_linked.emit(identity.duplicate(true))


class InvalidIdentity:
	extends RefCounted


var failures: Array[String] = []
var checks := 0


func check(what: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(what)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var identity := FakeIdentity.new()
	var modal := IdentityModal.new()
	root.add_child(modal)
	await process_frame

	check("the modal starts hidden", not modal.visible)
	check("a complete identity facade binds", modal.bind(identity) == {"ok": true})
	modal.open()
	var state: Dictionary = modal.view_state()
	check("open shows the modal", state["visible"])
	check("the current MOTD is shown", state["motd_visible"] and state["motd_title"] == "Season update")
	check("the MOTD body is shown", state["motd_body"] == "New rewards are live.")
	check("an HTTPS MOTD action is available", state["motd_action"])
	check("a linked provider is identified", state["providers"]["google"]["detail"] == "player@example.test")
	check("a linked provider offers disconnect", state["providers"]["google"]["action"] == "Disconnect")
	check("an unlinked provider offers connect", state["providers"]["apple"]["action"] == "Connect")

	var action_urls: Array[String] = []
	modal.motd_action_requested.connect(func(url: String) -> void: action_urls.append(url))
	var action_button := modal.find_child("MotdAction", true, false) as Button
	action_button.pressed.emit()
	check("the host owns MOTD navigation", action_urls == ["https://news.haiven.gg/season"])

	var apple_button := modal.find_child("AppleAction", true, false) as Button
	identity.suspend_link = true
	apple_button.pressed.emit()
	await process_frame
	check("connect delegates to the browser-backed facade", identity.link_calls == ["apple"])
	state = modal.view_state()
	check("a pending link disables every provider action", state["providers"]["google"]["disabled"] and state["providers"]["apple"]["disabled"])
	var duplicate_link: Dictionary = await modal.begin_link("apple")
	check("a duplicate link is rejected", duplicate_link.get("error") == "operation_in_progress")
	check("a duplicate link never reaches the facade", identity.link_calls == ["apple"])
	state = modal.view_state()
	check("a duplicate link preserves the active lock", state["providers"]["google"]["disabled"] and state["providers"]["apple"]["disabled"] and state["status"] == "Opening Apple…")
	identity.link_released.emit({"ok": true, "provider": "apple"})
	await process_frame
	state = modal.view_state()
	check("link completion releases the lock with finite browser guidance", not state["providers"]["google"]["disabled"] and not state["providers"]["apple"]["disabled"] and state["status"] == "Finish connecting Apple in the browser.")
	identity.complete_link("apple", "apple@example.test")
	state = modal.view_state()
	check("a realtime link event updates provider state", state["providers"]["apple"]["detail"] == "apple@example.test")
	check("the linked provider now offers disconnect", state["providers"]["apple"]["action"] == "Disconnect")
	check("a realtime link event announces completion", state["status"] == "Apple connected.")

	var google_button := modal.find_child("GoogleAction", true, false) as Button
	identity.suspend_unlink = true
	google_button.pressed.emit()
	await process_frame
	check("disconnect delegates to authenticated REST", identity.unlink_calls == ["google"])
	state = modal.view_state()
	check("a pending unlink disables every provider action", state["providers"]["google"]["disabled"] and state["providers"]["apple"]["disabled"])
	var duplicate_unlink: Dictionary = await modal.unlink("google")
	check("a duplicate unlink is rejected", duplicate_unlink.get("error") == "operation_in_progress")
	check("a duplicate unlink never reaches authenticated REST", identity.unlink_calls == ["google"])
	state = modal.view_state()
	check("a duplicate unlink preserves the active lock", state["providers"]["google"]["disabled"] and state["providers"]["apple"]["disabled"] and state["status"] == "Disconnecting Google…")
	identity.unlink_released.emit({"ok": true, "provider": "google"})
	await process_frame
	state = modal.view_state()
	check("disconnect removes the linked badge", state["providers"]["google"]["detail"] == "Not connected")
	check("disconnect restores the connect action", state["providers"]["google"]["action"] == "Connect")
	check("disconnect has finite success feedback", state["status"] == "Google disconnected.")

	identity.identity_link_failed.emit({"provider": "apple", "code": "popup_closed"})
	check("a link failure exposes its stable code", modal.view_state()["status"] == "Could not connect Apple (popup_closed).")
	identity.link_response = {"ok": false, "error": "popup_blocked"}
	var blocked: Dictionary = await modal.begin_link("google")
	check("a facade refusal is returned", blocked.get("error") == "popup_blocked")
	check("a facade refusal is visible", modal.view_state()["status"] == "Could not update Google (popup_blocked).")
	check("an invalid provider fails finitely", (await modal.begin_link("steam")).get("error") == "invalid_provider")

	var refresh_result: Dictionary = await modal.refresh()
	check("refresh attempts both identity reads", refresh_result.get("ok") and identity.motd_loads == 1 and identity.method_loads == 1)
	check("a successful refresh clears old status", modal.view_state()["status"] == "")

	var dismiss_button := modal.find_child("MotdDismiss", true, false) as Button
	dismiss_button.pressed.emit()
	check("dismiss delegates to the facade", identity.dismissals == 1)
	check("dismiss immediately hides the MOTD", not modal.view_state()["motd_visible"])

	var invalid_bind: Dictionary = modal.bind(InvalidIdentity.new())
	check("an invalid replacement is rejected", invalid_bind.get("error") == "identity_missing_begin_link")
	identity.complete_link("google", "again@example.test")
	check("an invalid replacement leaves the old binding live", modal.view_state()["providers"]["google"]["detail"] == "again@example.test")

	var closed_count := [0]
	modal.closed.connect(func() -> void: closed_count[0] += 1)
	var close_button := modal.find_child("Close", true, false) as Button
	close_button.pressed.emit()
	check("the close button hides once and emits once", not modal.visible and closed_count[0] == 1)
	modal.close()
	check("closing an already hidden modal is idempotent", closed_count[0] == 1)

	var snapshot: Dictionary = modal.view_state()
	snapshot["providers"]["google"]["detail"] = "mutated"
	check("view state is a defensive snapshot", modal.view_state()["providers"]["google"]["detail"] == "again@example.test")

	modal.unbind()
	check("unbind clears account and MOTD presentation", modal.view_state()["providers"]["google"]["detail"] == "Not connected" and not modal.view_state()["motd_visible"])
	check("operations fail closed after unbind", (await modal.begin_link("google")).get("error") == "identity_not_bound")

	modal.queue_free()
	if failures.is_empty():
		print("ok   GDScript identity modal")
		print("HAIVEN_TEST_PASS identity_modal %d" % checks)
		quit(0)
	else:
		for failure: String in failures:
			push_error(failure)
		print("FAIL GDScript identity modal: %d/%d failed" % [failures.size(), checks])
		quit(1)
