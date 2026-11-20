# Headless, real-engine proof for the packaged HTTPRequest transport. The Python
# harness supplies an ephemeral loopback origin; this script is copied without
# the addon and therefore imports the transport from the installed ZIP.
extends SceneTree

const HttpTransport := preload("res://addons/haiven/haiven_http_transport.gd")
const RestApi := preload("res://addons/haiven/haiven_rest_api.gd")
const RestError := preload("res://addons/haiven/haiven_rest_error.gd")

var failures: Array[String] = []
var checks := 0
var _token := "token-one"


func check(what: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(what)


func _initialize() -> void:
	call_deferred("_run")


func _transport(base_url: String, app_id: String = "app-one", token: Callable = _read_token) -> Node:
	var transport := HttpTransport.new(
		base_url,
		app_id,
		token,
		{"allow_insecure_loopback": true},
	)
	root.add_child(transport)
	return transport


func _read_token() -> String:
	return _token


func _run() -> void:
	var base_url := OS.get_environment("HAIVEN_HTTP_FIXTURE_BASE_URL")
	check("the harness supplies its loopback origin", not base_url.is_empty())

	var remote_http := HttpTransport.new("http://api.example.test/v0")
	check("remote plain HTTP is rejected", not remote_http.is_configured())
	check("the configuration explains the loopback exception", remote_http.configuration_error().contains("loopback"))
	var unknown_option := HttpTransport.new("https://api.example.test/v0", "", Callable(), {"surprise": true})
	check("transport options are closed", not unknown_option.is_configured())

	var secure := HttpTransport.new("https://api.example.test/root/v0///")
	check("HTTPS API roots configure", secure.is_configured())
	check("browser URLs use the normalized root", secure.url("/auth/sso/google") == "https://api.example.test/root/v0/auth/sso/google")

	var transport := _transport(base_url)
	check("opted-in loopback configures", transport.is_configured())
	var echo: Variant = await transport.request("GET", "/echo?tag=one", null, "")
	check("a real HTTPRequest decodes JSON", echo is Dictionary)
	check("GET reaches the fixture as GET", echo.get("method") == "GET")
	check("the API root and request path are joined", echo.get("path") == "/v0/echo")
	check("query values survive", echo.get("query", {}).get("tag", []) == ["one"])
	var headers: Dictionary = echo.get("headers", {})
	check("JSON is accepted", headers.get("accept") == "application/json")
	check("the SDK version header is sent", headers.get("x-haiven-sdk") == "godot/0.1.0-preview.1")  # x-release-please-version
	check("the bearer is sent", headers.get("authorization") == "Bearer token-one")
	check("the app id is sent", headers.get("x-haiven-app-id") == "app-one")
	check("bodyless calls omit Content-Type", not headers.has("content-type"))
	await process_frame
	check("completed HTTPRequest children are freed", transport.get_child_count() == 0)

	_token = "token-two"
	var refreshed: Dictionary = await transport.request("GET", "/echo", null, "")
	check("the token source is read for every call", refreshed.headers.authorization == "Bearer token-two")
	for method: String in ["POST", "PUT", "PATCH", "DELETE"]:
		var method_echo: Dictionary = await transport.request(method, "/echo", null, "")
		check("%s is not silently changed" % method, method_echo.method == method)

	var json_echo: Dictionary = await transport.request(
		"POST",
		"/echo",
		{"player": "one", "active": true},
		"application/json",
	)
	check("JSON requests declare their content type", json_echo.headers["content-type"] == "application/json")
	var decoded_body: Variant = JSON.parse_string(json_echo.body)
	check("JSON request bodies decode", decoded_body is Dictionary)
	check("JSON request values survive", decoded_body.get("player") == "one" and decoded_body.get("active") == true)

	var api := RestApi.new(transport.request, transport.url)
	var form_echo: Dictionary = await api.post_auth_handoff_exchange({"code": "one use/code", "state": "s&x"})
	check("the generated handoff request is form encoded", form_echo.headers["content-type"] == "application/x-www-form-urlencoded")
	check("form slashes and spaces round-trip", form_echo.form.get("code", []) == ["one use/code"])
	check("form ampersands do not create fields", form_echo.form.get("state", []) == ["s&x"])

	var public_transport := _transport(base_url, "", func() -> String: return "")
	var public_echo: Dictionary = await public_transport.request("GET", "/echo", null, "")
	check("an empty token omits Authorization", not public_echo.headers.has("authorization"))
	check("an empty app id omits its header", not public_echo.headers.has("x-haiven-app-id"))

	var empty: Variant = await transport.request("GET", "/empty", null, "")
	check("an empty 204 success returns null", empty == null)

	var limited: Variant = await transport.request("GET", "/error-json", null, "")
	check("a JSON HTTP failure returns HaivenRestError", limited is RestError)
	check("the HTTP status is retained", limited.status_code == 429)
	check("an open server error code is retained", limited.code == "rate_limited")
	check("429 is retryable", limited.is_retryable())

	var unavailable: Variant = await transport.request("GET", "/error-text", null, "")
	check("a text HTTP failure returns HaivenRestError", unavailable is RestError)
	check("a text failure retains status", unavailable.status_code == 503)
	check("a text failure retains its body", unavailable.body == "temporarily unavailable")
	check("503 is retryable", unavailable.is_retryable())

	var malformed: Variant = await transport.request("GET", "/invalid-json", null, "")
	check("malformed success JSON is an error", malformed is RestError)
	check("malformed success JSON has a finite code", malformed.code == "sdk_invalid_response")
	check("a malformed success is not retryable", not malformed.is_retryable())

	var unsafe: Variant = await transport.request("GET", "/unsafe-int", null, "")
	check("an unsafe integer is an error", unsafe is RestError)
	check("unsafe integers use the established code", unsafe.code == "integer_precision_exceeded")
	check("an unsafe integer is not retried", not unsafe.is_retryable())

	var redirect: Variant = await transport.request("GET", "/redirect", null, "")
	check("a redirect is returned as an error", redirect is RestError)
	check("redirects are not followed", redirect.status_code == 302)
	check("a refused redirect is not retryable", not redirect.is_retryable())

	var bad_method: Variant = await transport.request("TRACE", "/echo", null, "")
	check("unknown methods fail closed", bad_method is RestError and bad_method.code == "sdk_invalid_request")
	var bad_content: Variant = await transport.request("POST", "/echo", {}, "text/plain")
	check("unknown body encodings fail closed", bad_content is RestError and bad_content.code == "sdk_invalid_request")

	var bad_app := HttpTransport.new(base_url, "app\r\nX-Evil: one", Callable(), {"allow_insecure_loopback": true})
	check("app-id header injection invalidates configuration", not bad_app.is_configured())
	var bad_app_result: Variant = await bad_app.request("GET", "/echo", null, "")
	check("invalid configuration has a finite code", bad_app_result.code == "sdk_invalid_configuration")

	var bad_token := _transport(base_url, "", func() -> String: return "token\r\nX-Evil: one")
	var bad_token_result: Variant = await bad_token.request("GET", "/echo", null, "")
	check("token header injection fails before I/O", bad_token_result is RestError and bad_token_result.code == "sdk_invalid_configuration")

	for path: String in ["", "//evil.test/v0", "/../echo", "/%2e%2e/echo", "/echo#fragment"]:
		var bad_path: Variant = await transport.request("GET", path, null, "")
		check("hostile path is rejected: %s" % path, bad_path is RestError and bad_path.code == "sdk_invalid_request")

	var detached := HttpTransport.new("https://api.example.test/v0")
	var detached_result: Variant = await detached.request("GET", "/echo", null, "")
	check("a detached transport fails instead of hanging", detached_result is RestError and detached_result.code == "sdk_invalid_configuration")

	# Let queued HTTPRequest children and the transport nodes leave the tree before
	# ending the process, so the engine gate also proves resource-clean teardown.
	for child: Node in root.get_children():
		child.queue_free()
	for detached_node: Node in [remote_http, unknown_option, secure, bad_app, detached]:
		detached_node.free()
	await process_frame
	call_deferred("_report")


func _report() -> void:
	if failures.is_empty():
		print("ok   packaged HTTPRequest transport")
		print("HAIVEN_TEST_PASS http_transport %d" % checks)
		quit(0)
		return
	for failure in failures:
		print("FAIL ", failure)
	print("failed %d of %d checks" % [failures.size(), checks])
	quit(1)
