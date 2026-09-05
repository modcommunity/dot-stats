@tool
class_name DotStatsClient
extends Node

## A player's own statistics, reported by their own client with their own token.
##
## The other surface. [DotStatsTracker] runs where an integration credential
## is — a server, the app's service — and files figures about every player it
## sees. This runs in the game the player is holding, and files figures about
## [b]one[/b] player, the one signed in, with the access token dot-auth's
## device flow issued them. There is no integration token anywhere near it,
## which is what makes it safe to ship in a client build.
##
## [codeblock]
## var mine := DotStatsClient.new()
## mine.schema = preload("res://stats.tres")
## mine.client = auth_client              # dot-auth's DotAuthClient, duck-typed
## add_child(mine)
##
## mine.record(&"launches")               # +1 on a counter
## mine.record(&"longest_session", 1830.0) # a best keeps the higher
## var res := await mine.fetch_mine()     # what the site holds for me
## [/codeblock]
##
## [b]Self-reported means the player chose the numbers.[/b] Nothing here
## proves a figure; the backbone files it under the player's app-scoped key,
## and the app's own service reads it back through the integration API. A game
## should treat these as a player's diary — launches, time in menus, settings
## preferences — and keep anything competitive on the server.
##
## [b]Which app.[/b] A game session credential — the one the web player hands
## over — is bound to an app already, and the backbone refuses any other. A
## device credential is not, so a desktop build sets [member app_id]. The
## backbone's [code]stats/*[/code] routes take the same [code]app[/code] field
## either way.
##
## Deltas, coalesced by kind, as the tracker does — the same rule, so what
## reaches the site is "add 3" and the order of arrival does not matter.

const CHANNEL := "stats.client"

const SUBMIT_PATH := "stats/submit"
const MINE_PATH := "stats/me"
const TOP_PATH := "stats/top"

## Emitted after each flush, successful or not.
signal reported(result: DotResult)

@export var schema: DotStatsSchema = null

## Read the schema from this JSON file when [member schema] is unset.
@export_file("*.json") var schema_file: String = ""

## The app these figures belong to. 0 leaves it to the credential, which is
## right for a game session token and wrong for a device token.
@export var app_id: int = 0

## Seconds between flushes. 0 leaves flushing to the caller.
@export_range(0.0, 600.0, 1.0) var report_interval: float = 30.0

## The player's client. Any object with `post_app(path, body)` and
## `get_app(path, query)` — dot-auth's [code]DotAuthClient[/code], which is
## not named here for the family's reason.
var client: Object = null

var _session := DotStatsValues.new()
var _delta := DotStatsValues.new()
var _timer: Timer = null
var _started: bool = false
var sent: int = 0
var failures: int = 0
var last_error: String = ""


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var res := start()
	if not res.ok:
		DotLog.result(CHANNEL, "stats client", res)


func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if schema == null and schema_file != "":
		var loaded := DotStatsSchema.load_json(schema_file)
		if not loaded.ok:
			return loaded
		schema = loaded.value

	if schema == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The stats client has no schema.", "assign schema or schema_file"
		)

	var valid := schema.validate()
	if not valid.ok:
		return valid

	if report_interval > 0.0:
		_timer = Timer.new()
		_timer.name = "ReportTimer"
		_timer.wait_time = report_interval
		_timer.autostart = true
		_timer.timeout.connect(_on_report_due)
		add_child(_timer)

	_started = true
	return DotResult.success(self)


func _exit_tree() -> void:
	if _started and not _delta.is_empty() and is_available():
		await flush()


func is_available() -> bool:
	return client != null and client.has_method("post_app") and client.has_method("get_app")


## Applies a reading to the session and the delta, by the stat's kind.
func record(stat_id: StringName, value: float = 1.0) -> DotResult:
	if not _started:
		var s := start()
		if not s.ok:
			return s

	var def := schema.find(stat_id)
	if def == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "No such stat is declared.", String(stat_id)
		)

	var applied := _session.record(def, value)
	if not applied.ok:
		return applied
	if def.publish:
		_delta.record(def, value)
	return applied


## This session's values so far. Never sent; for the game's own screen.
func session_values() -> DotStatsValues:
	return _session


func pending() -> int:
	return _delta.size()


## Sends the delta. Kept on failure, cleared on success.
func flush() -> DotResult:
	if _delta.is_empty():
		return DotResult.success(0)

	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE,
			"No client to report through.",
			"assign DotStatsClient.client from dot-auth's DotAuthClient"
		)

	var body := {"stats": _delta.to_dictionary()}
	if app_id > 0:
		body["app"] = app_id

	var result: Variant = await client.call("post_app", SUBMIT_PATH, body)
	if not (result is DotResult):
		failures += 1
		last_error = "the client returned something that is not a DotResult"
		return DotResult.fail(DotError.CODE_INTERNAL, last_error)

	var typed := result as DotResult
	if not typed.ok:
		failures += 1
		last_error = typed.error.message
		DotLog.warn(CHANNEL, "could not report my stats; keeping them", {"why": last_error})
		reported.emit(typed)
		return typed

	var count := _delta.size()
	_delta.clear()
	sent += count
	last_error = ""
	reported.emit(typed)
	return DotResult.success(count)


## What the site holds for this player under the app.
func fetch_mine() -> DotResult:
	if not is_available():
		return DotResult.fail(DotError.CODE_STATE, "No client to read through.")
	var query := {}
	if app_id > 0:
		query["app"] = app_id
	var result: Variant = await client.call("get_app", MINE_PATH, query)
	if not (result is DotResult):
		return DotResult.fail(DotError.CODE_INTERNAL, "the client returned something that is not a DotResult")
	return result as DotResult


## One stat as a ranking, with this player's own rank beside it.
func fetch_top(stat_id: StringName, limit: int = 25, offset: int = 0) -> DotResult:
	if not is_available():
		return DotResult.fail(DotError.CODE_STATE, "No client to read through.")
	var query := {"stat": String(stat_id), "limit": limit, "offset": offset}
	if app_id > 0:
		query["app"] = app_id
	var result: Variant = await client.call("get_app", TOP_PATH, query)
	if not (result is DotResult):
		return DotResult.fail(DotError.CODE_INTERNAL, "the client returned something that is not a DotResult")
	return result as DotResult


func _on_report_due() -> void:
	await flush()


func describe() -> Dictionary:
	return {
		"available": is_available(),
		"app": app_id,
		"pending": _delta.size(),
		"sent": sent,
		"failures": failures,
		"last_error": last_error,
		"session": _session.to_dictionary(),
	}
