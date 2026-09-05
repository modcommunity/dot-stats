class_name DotStatsReporter
extends RefCounted

## Sends players' statistics to the TMC backbone, coalesced and in batches,
## without losing them.
##
## [b]dot-auth is not a dependency and [code]DotBackboneClient[/code] is not
## named.[/b] The family rule: a script that mentions an absent
## [code]class_name[/code] fails to parse. The client is held as an [Object] and
## its [code]post_integration(path, body)[/code] is called by name — the generic
## hook dot-auth exposes for exactly this. It stamps [code]ts[/code] and
## [code]nonce[/code], adds the bearer header and rate-limits locally, so
## everything about authenticating to the backbone lives in one place and this
## class does not know a token exists. The same seam dot-leaderboard's reporter
## uses, so a game wires one client and both report through it.
##
## [b]Coalesced, because a stat is a running figure and not an event.[/b] A
## player who scored forty kills between two flushes is one row saying forty,
## not forty rows. Readings for one player are merged by the stat's own kind
## before anything is sent — counters sum, gauges keep the newest, bests keep the
## higher — which is the same rule the backbone applies on arrival, so the order
## in which the pieces land does not change the answer.
##
## [b]Queued and retried, and bounded.[/b] Nothing is sent per event. A failed
## flush keeps the queue; it is only emptied after the backbone said yes, because
## re-queueing on failure reorders against a flush already in progress. The queue
## is bounded by [b]players[/b], not readings — coalescing makes a player's row
## the unit — and past the bound the oldest player is dropped, since the row
## somebody is waiting to see is the newest one.
##
## [b]The credential decides whose stats these are.[/b] Nothing in a body names
## an app or a server: an app-scoped integration files app-wide figures, a
## server-scoped one files that server's, and the site rolls the second up into
## the first. See [code]docs/api/integration-api.md[/code] in website-city.
##
## [b]A player id is a pseudonym, never an account id.[/b] It is the per-scope
## key dot-user's [code]DotUserScope[/code] derives, or the one the backbone's
## [code]play/scope-key[/code] hands a client on join. An id shaped like a
## dot-auth account uid ([code]backbone:…[/code]) is refused here, because a
## server that filed those would hand every operator a stable global identifier
## for every player — the thing the scoped key exists to prevent — and it would
## do so without anything failing.

const CHANNEL := "stats.report"

## The integration endpoints, relative to `/api/integration/v1/`.
const SUBMIT_PATH := "stats/submit"
const DEFINE_PATH := "stats/define"

## The scope an integration needs. Named so a 403 can say which box to tick.
const SCOPE_WRITE := "STATS_WRITE"
const SCOPE_READ := "STATS_READ"

const PLAYER_PATH := "stats/player"
const TOP_PATH := "stats/top"

## Prefix of an account-shaped id this reporter refuses as a player.
const ACCOUNT_PREFIX := "backbone:"

## The backbone client. Any object with `post_integration(String, Dictionary)`.
var client: Object = null

## The stats readings are checked against and coalesced by.
var schema: DotStatsSchema = null

## Players held between flushes. Past this the oldest player is dropped.
##
## A player's row is a few hundred bytes, so five hundred is a full server's
## worth several times over and well under the request cap.
var player_limit: int = 500

## Players per request. Matched to what the backbone caps a submission at.
var batch_limit: int = 50

## player id -> {"name": String, "values": DotStatsValues}, in arrival order.
var _queue: Dictionary = {}

var sent: int = 0
var dropped: int = 0
var failures: int = 0
var last_error: String = ""


static func with_client(p_client: Object, p_schema: DotStatsSchema) -> DotStatsReporter:
	var r := DotStatsReporter.new()
	r.client = p_client
	r.schema = p_schema
	return r


func is_available() -> bool:
	return client != null and client.has_method("post_integration") and schema != null


## Whether an id may be filed as a player.
static func is_player_id(candidate: String) -> bool:
	if candidate.strip_edges() == "" or candidate.length() > 64:
		return false
	if candidate.begins_with(ACCOUNT_PREFIX):
		return false
	return true


## Queues a player's readings. Coalesced into what is already held for them.
##
## [param readings] is stat id -> value. A stat the schema does not declare, or
## does not publish, is skipped with a warning the first time — the backbone
## would refuse the whole batch for it, and a game that renamed a stat should
## find out from a log line rather than from every submission failing.
func queue(player_id: StringName, player_name: String, readings: Dictionary) -> DotResult:
	if schema == null:
		return DotResult.fail(DotError.CODE_STATE, "The reporter has no schema.")

	if not is_player_id(String(player_id)):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A player id must be a pseudonymous scoped key, not an account id.",
			String(player_id).substr(0, 16)
		)

	var row: Dictionary = _queue.get(player_id, {})
	var values: DotStatsValues = row.get("values", DotStatsValues.new())
	var accepted := 0

	for key in readings:
		var id := StringName(str(key))
		var def := schema.find(id)
		if def == null or not def.publish:
			_warn_once(id, "unknown" if def == null else "unpublished")
			continue
		var raw: Variant = readings[key]
		if not (raw is float or raw is int):
			continue
		var recorded := values.record(def, float(raw))
		if recorded.ok:
			accepted += 1

	if accepted == 0:
		return DotResult.success(0)

	# Re-inserted rather than updated in place so a player who keeps scoring
	# moves to the newest end and is the last to be dropped.
	_queue.erase(player_id)
	_queue[player_id] = {"name": player_name.substr(0, 64), "values": values}

	while _queue.size() > player_limit:
		var oldest: Variant = _queue.keys()[0]
		_queue.erase(oldest)
		dropped += 1
		if dropped == 1 or dropped % 100 == 0:
			DotLog.warn(
				CHANNEL,
				"the stats queue is full; dropping the oldest player",
				{"limit": player_limit, "dropped": dropped}
			)

	return DotResult.success(accepted)


func queued() -> int:
	return _queue.size()


## Sends up to [member batch_limit] players. Removes them only on success.
func flush() -> DotResult:
	if _queue.is_empty():
		return DotResult.success(0)

	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone client to report through.",
			"assign DotStatsReporter.client from dot-auth's DotBackboneClient"
		)

	var ids: Array = _queue.keys()
	var count := mini(ids.size(), batch_limit)
	var players: Array = []

	for i in range(count):
		var row: Dictionary = _queue[ids[i]]
		players.append({
			"player": String(ids[i]),
			"name": str(row["name"]),
			"stats": (row["values"] as DotStatsValues).to_dictionary(),
		})

	var result: Variant = await client.call(
		"post_integration", SUBMIT_PATH, {"players": players}
	)

	if not (result is DotResult):
		failures += 1
		last_error = "the client returned something that is not a DotResult"
		return DotResult.fail(DotError.CODE_INTERNAL, last_error)

	var typed := result as DotResult
	if not typed.ok:
		failures += 1
		last_error = typed.error.message
		if typed.error.http_status == 403:
			# Will not fix itself; retrying it for ever only fills the log.
			DotLog.warn(
				CHANNEL,
				"the backbone refused the report; the integration may lack a scope",
				{"need": SCOPE_WRITE}
			)
		else:
			DotLog.warn(
				CHANNEL,
				"stats report failed; keeping the queue",
				{"why": typed.error.message, "queued": _queue.size()}
			)
		return typed

	for i in range(count):
		_queue.erase(ids[i])
	sent += count
	last_error = ""

	DotLog.debug(CHANNEL, "stats reported", {"players": count})
	return DotResult.success(count)


## Flushes until the queue is empty or a flush fails.
func flush_all() -> DotResult:
	var total := 0
	while not _queue.is_empty():
		var res := await flush()
		if not res.ok:
			return res
		total += int(res.value)
	return DotResult.success(total)


## Declares the schema's published stats to the backbone.
##
## Idempotent on the backbone's side: send the whole table at boot and only the
## changed ones move. Presentation — a name, a unit — is editorial and separate
## from filing, which is why this is its own call rather than folded into the
## first submission.
func define() -> DotResult:
	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE, "No backbone client to declare through."
		)

	var list: Array = []
	for d in schema.published():
		list.append(wire_definition(d))

	if list.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE,
			"No stat is published; there is nothing to declare.",
			"set DotStatsDef.publish on the ones the site should hold"
		)

	var result: Variant = await client.call(
		"post_integration", DEFINE_PATH, {"stats": list}
	)
	if not (result is DotResult):
		return DotResult.fail(
			DotError.CODE_INTERNAL, "the client returned something that is not a DotResult"
		)
	return result as DotResult


# --- Reading the backbone's copy ------------------------------------------

## Every value the backbone holds for [param player_id] under this credential.
##
## Through the client's `get_integration`, which needs `STATS_READ` — a scope
## kept separate from writing so a HUD that reads can never file. The value is
## the backbone's reply: [code]{player, name, stats: [{key, name, kind, unit,
## decimals, value}, …]}[/code].
func fetch_player(player_id: StringName) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone client that can read.",
			"the client needs get_integration(path, query)"
		)

	var result: Variant = await client.call(
		"get_integration", PLAYER_PATH, {"player": String(player_id)}
	)
	return _read_result(result)


## One stat as a ranking: the players holding its best values.
##
## [param player_id], when given, adds a [code]self[/code] row with that
## player's derived rank whether or not they are on the page.
func fetch_top(
	stat_id: StringName,
	limit: int = 25,
	offset: int = 0,
	player_id: StringName = &""
) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone client that can read.",
			"the client needs get_integration(path, query)"
		)

	var query := {"stat": String(stat_id), "limit": limit, "offset": offset}
	if player_id != &"":
		query["player"] = String(player_id)

	var result: Variant = await client.call("get_integration", TOP_PATH, query)
	return _read_result(result)


func _read_result(result: Variant) -> DotResult:
	if not (result is DotResult):
		return DotResult.fail(
			DotError.CODE_INTERNAL, "the client returned something that is not a DotResult"
		)
	var typed := result as DotResult
	if not typed.ok and typed.error.http_status == 403:
		DotLog.warn(
			CHANNEL,
			"the backbone refused the read; the integration may lack a scope",
			{"need": SCOPE_READ}
		)
	return typed


var _warned: Dictionary = {}


func _warn_once(id: StringName, why: String) -> void:
	if _warned.has(id):
		return
	_warned[id] = true
	DotLog.warn(
		CHANNEL,
		"a reading names a stat that will not be reported",
		{"stat": String(id), "why": why}
	)


func describe() -> Dictionary:
	return {
		"available": is_available(),
		"queued": _queue.size(),
		"sent": sent,
		"dropped": dropped,
		"failures": failures,
		"last_error": last_error,
	}


## A stat as the backbone's `StatsDefineInput` names it: `key` on the wire, `id`
## here. `to_dictionary()` is this addon's file format, not the wire, and sending it
## had every definition refused by the schema — the two ends had never met.
static func wire_definition(d: DotStatsDef) -> Dictionary:
	return {
		"key": String(d.id),
		"name": d.display_name,
		"description": d.description,
		"kind": d.kind_name(),
		"unit": d.unit,
		"decimals": d.decimals,
		"visible": d.visible,
	}
