# Runner #4 of the client corpus: HaivenSession against a scripted server.
#
# gaming-client/v0 (conformance/gaming-client/v0) scripts exactly the frames a server sends.
# This drives the addon's session through a scripted socket that answers the
# same polling calls a WebSocketPeer does, and asserts what the session wrote
# and what it handed to its caller -- the scenarios the TypeScript, C# and C++
# runners execute against their own session cores. The suite is read from
# HAIVEN_CLIENT_SUITE because the project is copied out of the repository.
extends SceneTree

const Session := preload("res://addons/haiven/haiven_session.gd")

## The names this runner answers to in a scenario's `waivers`.
const RUNNER := "godot-headless"
const PROFILE := "gaming/godot"


## The transport a scenario drives: the polling surface of a WebSocketPeer.
class ScriptedSocket:
	extends RefCounted

	var ready_state := WebSocketPeer.STATE_CONNECTING
	var sent: Array[Dictionary] = []
	var inbox: Array[String] = []

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return ready_state

	func get_available_packet_count() -> int:
		return inbox.size()

	func get_packet() -> PackedByteArray:
		return inbox.pop_front().to_utf8_buffer()

	func send_text(text: String) -> int:
		sent.append(JSON.parse_string(text))
		return OK

	func close(_code: int = 1000, _reason: String = "") -> void:
		ready_state = WebSocketPeer.STATE_CLOSED

	func get_close_code() -> int:
		return 1000

	func get_close_reason() -> String:
		return ""


const STATES := {
	Session.State.PENDING: "pending",
	Session.State.AUTHENTICATED: "authenticated",
	Session.State.EXPIRED: "expired",
	Session.State.CLOSED: "closed",
}


func _initialize() -> void:
	var path := OS.get_environment("HAIVEN_CLIENT_SUITE")
	var suite: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(suite) != TYPE_DICTIONARY:
		print("FAIL could not read the client suite at %s" % path)
		quit(1)
		return

	var claimed := [RUNNER, PROFILE, String(suite.get("lifecycle", ""))]
	var failures: Array[String] = []
	var ran := 0
	for scenario in suite.get("scenarios", []):
		var waivers: Dictionary = scenario.get("waivers", {})
		var waived := false
		for name in claimed:
			if waivers.has(name):
				print("waived %s: %s" % [scenario.get("id"), waivers[name]])
				waived = true
		if waived:
			continue
		ran += 1
		var failure := _run(scenario)
		if failure != "":
			failures.append("%s: %s" % [scenario.get("id"), failure])

	if ran == 0:
		failures.append("the suite has no scenario this runner can run")
	for failure in failures:
		print("FAIL " + failure)
	if failures.is_empty():
		print("ok   GDScript client conformance (gaming-client/v0), %d scenarios" % ran)
		print("HAIVEN_TEST_PASS client %d" % ran)
		quit(0)
	else:
		quit(1)


## Replaces every {"ref": alias} with the request id bound to that alias.
func _resolve(value: Variant, bound: Dictionary) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		if value.size() == 1 and value.has("ref"):
			return bound[value["ref"]]
		var copy := {}
		for key in value:
			copy[key] = _resolve(value[key], bound)
		return copy
	if typeof(value) == TYPE_ARRAY:
		var items := []
		for item in value:
			items.append(_resolve(item, bound))
		return items
	return value


## Runs one scenario; returns the failure, or an empty string.
func _run(scenario: Dictionary) -> String:
	var socket := ScriptedSocket.new()
	var counter := [0]
	var session := Session.new(
		socket,
		func() -> String: return "scripted-token",
		func() -> String:
			counter[0] += 1
			return "rq-%d" % counter[0]
	)
	var delivered: Array[Dictionary] = []
	session.frame_received.connect(func(frame: Dictionary) -> void: delivered.append(frame))
	var bound := {}
	var read := 0
	var seen := 0
	var steps: Array = scenario.get("steps", [])

	for index in steps.size():
		var step: Dictionary = steps[index]
		var verb: String = step.get("do", "")
		var at := "step %d (%s)" % [index + 1, verb]
		match verb:
			"open":
				socket.ready_state = WebSocketPeer.STATE_OPEN
				session.poll()
			"call":
				session.send(step.get("type"), step.get("payload"))
			"serve":
				socket.inbox.append(JSON.stringify(_resolve(step.get("frame"), bound)))
				session.poll()
			"expectSent":
				if read >= socket.sent.size():
					return "%s: expected a %s and nothing was written" % [at, step.get("type")]
				var frame: Dictionary = socket.sent[read]
				read += 1
				if frame.get("type") != step.get("type"):
					return "%s: wrote %s" % [at, frame.get("type")]
				var request_id: String = frame.get("requestId", "")
				if step.has("bind"):
					bound[step["bind"]] = request_id
				if step.has("same") and bound.get(step["same"]) != request_id:
					return "%s: wrote %s, not %s" % [at, request_id, step["same"]]
			"expectQuiet":
				if read < socket.sent.size():
					return "%s: also wrote a %s" % [at, socket.sent[read].get("type")]
			"expectState":
				var state: String = STATES[session.state]
				if state != step.get("state"):
					return "%s: is %s" % [at, state]
			"expectDelivered":
				var found := seen
				while found < delivered.size() and delivered[found].get("type") != step.get("type"):
					found += 1
				if found == delivered.size():
					return "%s: no %s was handed to the caller" % [at, step.get("type")]
				var frame: Dictionary = delivered[found]
				seen = found + 1
				if step.has("error") and frame.get("error") != step["error"]:
					return "%s: error %s" % [at, frame.get("error")]
			_:
				return "%s: unknown step" % at
	return ""
