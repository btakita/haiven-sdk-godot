# Does GDScript refuse an integer it cannot decode exactly?
#
# `JSON.parse_string` reads every number as a float, integers included, so an
# integer literal beyond 2^53 - 1 arrives rounded with no error. This measures
# that premise first, then the guard: the raw-text scanner, the session's
# decode_error signal, and the handoff exchange's refusal.
extends SceneTree

const Protocol := preload("res://addons/haiven/haiven_protocol.gd")
const Session := preload("res://addons/haiven/haiven_session.gd")
const Handoff := preload("res://addons/haiven/haiven_handoff.gd")
const TokenStore := preload("res://addons/haiven/haiven_token_store.gd")

const CODE := "integer_precision_exceeded"

var failures: Array[String] = []
var checks := 0


## The polling surface of a WebSocketPeer, scripted.
class ScriptedSocket:
	extends RefCounted

	var ready_state := WebSocketPeer.STATE_OPEN
	var inbox: Array[String] = []

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return ready_state

	func get_available_packet_count() -> int:
		return inbox.size()

	func get_packet() -> PackedByteArray:
		return inbox.pop_front().to_utf8_buffer()

	func send_text(_text: String) -> int:
		return OK

	func close(_code: int = 1000, _reason: String = "") -> void:
		ready_state = WebSocketPeer.STATE_CLOSED

	func get_close_code() -> int:
		return 1000

	func get_close_reason() -> String:
		return ""


func check(what: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(what)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# The premise. If Godot ever decodes integers exactly, this guard is moot.
	var rounded: Dictionary = JSON.parse_string('{"n":9007199254740993}')
	check("JSON.parse_string decodes an integer as a float", typeof(rounded["n"]) == TYPE_FLOAT)
	check("so 2^53 + 1 arrives as 2^53", int(rounded["n"]) == 9007199254740992)

	_scanner()
	_session()
	await _handoff()
	_report()


func _scanner() -> void:
	check("2^53 + 1 is found", Protocol.find_unsafe_integer('{"n":9007199254740993}') == "9007199254740993")
	check("2^53 is found, because 2^53 + 1 rounds to it", Protocol.find_unsafe_integer('{"n":9007199254740992}') == "9007199254740992")
	check("2^53 - 1 is accepted", Protocol.find_unsafe_integer('{"n":9007199254740991}') == "")
	check("-(2^53 - 1) is accepted", Protocol.find_unsafe_integer('{"n":-9007199254740991}') == "")
	check("-(2^53 + 1) is found with its sign", Protocol.find_unsafe_integer('[-9007199254740993]') == "-9007199254740993")
	check("a 30-digit literal is found", Protocol.find_unsafe_integer('{"n":123456789012345678901234567890}') == "123456789012345678901234567890")
	check("a big number inside a string is ignored", Protocol.find_unsafe_integer('{"id":"9007199254740993"}') == "")
	check(
		"an escaped quote does not end the string early",
		Protocol.find_unsafe_integer('{"s":"a\\"9007199254740993\\"b","n":1}') == "",
	)
	check("a number after a string is still scanned", Protocol.find_unsafe_integer('{"s":"x","n":9007199254740993}') == "9007199254740993")
	check("an exponent form is a float and not checked", Protocol.find_unsafe_integer('{"n":9007199254740993e0}') == "")
	check("a negative exponent form is not checked", Protocol.find_unsafe_integer('{"n":-9007199254740993E+2}') == "")
	check("a fraction is a float and not checked", Protocol.find_unsafe_integer('{"n":9007199254740993.5}') == "")
	check("a normal frame passes", Protocol.find_unsafe_integer('{"type":"pong","requestId":"rq-1","success":true}') == "")


func _session() -> void:
	var socket := ScriptedSocket.new()
	var session := Session.new(socket, func() -> String: return "token")
	var errors: Array[Array] = []
	var frames: Array[Dictionary] = []
	session.decode_error.connect(func(code: String, message: String) -> void: errors.append([code, message]))
	session.frame_received.connect(func(frame: Dictionary) -> void: frames.append(frame))

	socket.inbox.append('{"type":"auth.success","requestId":"req-1","success":true}')
	socket.inbox.append('{"type":"inventory.updated","payload":{"amount":9007199254740993}}')
	socket.inbox.append('{"type":"inventory.updated","payload":{"amount":9007199254740991,"id":"9007199254740993"}}')
	session.poll()

	check("the unsafe frame raises decode_error once", errors.size() == 1)
	check("with the SDK-local code", errors.size() == 1 and errors[0][0] == CODE)
	check("naming the literal", errors.size() == 1 and String(errors[0][1]).contains("9007199254740993"))
	check("the code is exported from the protocol", Protocol.INTEGER_PRECISION_EXCEEDED == CODE)
	check("the unsafe frame is not delivered, a safe one is", frames.size() == 2)
	check(
		"2^53 - 1 is delivered exactly",
		frames.size() == 2 and int(frames[1]["payload"]["amount"]) == 9007199254740991,
	)
	check("the session stays open", session.state == Session.State.AUTHENTICATED)


func _handoff() -> void:
	var tokens := TokenStore.new("old-access")
	var handoff := Handoff.new(
		{
			"entry_url": "https://app.haiven.gg/connect/game",
			"exchange_url": "https://api.haiven.gg/v0/auth/handoff/exchange",
			"integration_id": "example-game",
			"redirect_url": "haiven-example://auth/callback",
		},
		tokens,
		func(_url: String) -> int: return OK,
		func(_url: String, _headers: PackedStringArray, _body: String) -> Dictionary:
			return {
				"status": 200,
				"body": '{"access_token":"a","token_type":"Bearer","expires_in":9007199254740993}',
			},
		func() -> int: return 1_789_646_400_000,
		func(size: int) -> PackedByteArray:
			var bytes := PackedByteArray()
			bytes.resize(size)
			bytes.fill(7)
			return bytes,
	)
	root.add_child(handoff)
	var start: Dictionary = handoff.begin_login()
	var result: Dictionary = await handoff.complete(
		"haiven-example://auth/callback?code=c&state=%s" % String(start.get("state", "")).uri_encode()
	)
	check("the handoff exchange refuses an unsafe integer", result.get("error") == CODE)
	check("and does not replace the session token", tokens.read() == "old-access")


func _report() -> void:
	if failures.is_empty():
		print("ok   GDScript integer precision guard")
		print("HAIVEN_TEST_PASS integer_precision %d" % checks)
		quit(0)
		return
	for failure in failures:
		print("FAIL ", failure)
	quit(1)
