@tool
class_name DotStatsTracker
extends Node

## Counts statistics for the players on a server and reports them.
##
## The runtime half of dot-stats: a game calls [method record] as things happen,
## the tracker keeps a per-player set for the session and a delta since the last
## report, and on a timer it hands the deltas to a [DotStatsReporter] and forgets
## them. A player who leaves is reported one last time and dropped.
##
## [codeblock]
## var tracker := DotStatsTracker.new()
## tracker.schema = preload("res://stats.tres")
## tracker.reporter.client = backbone      # dot-auth's DotBackboneClient
## add_child(tracker)
##
## tracker.begin(player_key, display_name)  # on join; player_key is the scoped id
## tracker.record(player_key, &"kills")     # +1 on a counter
## tracker.record(player_key, &"top_speed", 41.2)   # a best keeps the higher
## tracker.end(player_key)                  # on leave; reports and forgets
## [/codeblock]
##
## [b]Where this runs.[/b] On the process that holds the integration credential:
## a dedicated server, or the app's own service. Never in a client build — an
## integration token in a client is a token in every player's hands, and a stat
## a client reports about itself is a stat it chose.
##
## [b]Deltas, not totals, leave the process.[/b] A counter's delta is what was
## added since the last flush; a gauge's is its newest reading; a best's is the
## best since. The backbone merges each by the same kind, so two servers
## reporting the same player, or one server restarting mid-session, add up
## rather than overwrite. The session set is for the game's own HUD and is never
## sent.
##
## [b]And optionally a store of lifetime totals, beside the backbone or instead of it.[/b]
## With [member store] set, every delta the tracker would report is also merged into the
## store at the same moment — a checkpoint (a flush, a leave, shutdown) — by the same rule.
## A server with no backbone still keeps every player's totals; one with both keeps both,
## and the two cannot disagree about which readings they were told of.

const CHANNEL := "stats"

## Emitted when a reading is recorded. [param value] is the session value after it.
signal recorded(player_id: StringName, stat_id: StringName, value: float)

## Emitted when a reading is refused: an undeclared stat, a non-finite number.
signal refused(player_id: StringName, stat_id: StringName, reason: String)

## Emitted after each flush, successful or not.
signal reported(result: DotResult)

## Emitted after each write to [member store], successful or not.
signal stored(result: DotResult)

@export_group("Stats")

@export var schema: DotStatsSchema = null

## Read the schema from this JSON file when [member schema] is unset.
@export_file("*.json") var schema_file: String = ""

@export_group("Reporting")

## Hand deltas to the reporter, at all.
##
## Off, every counter still works and nothing leaves the process. On, only stats
## marked [member DotStatsDef.publish] go.
@export var report_to_backbone: bool = false

## Seconds between flushes. 0 leaves flushing to the caller.
@export_range(0.0, 600.0, 1.0) var report_interval: float = 30.0

## Declare the schema to the backbone when reporting starts.
@export var define_on_start: bool = true

var reporter := DotStatsReporter.new()

## Where lifetime totals are kept: a [DotStatsStore], or anything with the same
## [code]merge(player_id, values, schema, player_name)[/code] coroutine. Null keeps none.
##
## [b]Untyped on purpose[/b], so a game can hand it its own store — one that writes through
## a service it already has — without subclassing anything. Assign it before the tracker
## enters the tree, so the flush timer is started for it; a store that suspends must be
## opened first.
var store = null

## player id -> {"name": String, "session": DotStatsValues, "delta": DotStatsValues}
var _players: Dictionary = {}
var _timer: Timer = null
var _started: bool = false
var _defined: bool = false

## player id -> {"name": String, "values": DotStatsValues}: deltas checkpointed for the store
## and not yet written to it. The store's half of what the reporter's queue is.
var _store_pending: Dictionary = {}
var _store_writing: bool = false
var _store_failing: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var res := start()
	if not res.ok:
		DotLog.result(CHANNEL, "stats tracker", res)


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
			DotError.CODE_STATE, "The tracker has no schema.", "assign schema or schema_file"
		)

	var valid := schema.validate()
	if not valid.ok:
		return valid

	reporter.schema = schema
	if store != null and store.get("schema") == null:
		store.set("schema", schema)

	if (report_to_backbone or store != null) and report_interval > 0.0:
		_timer = Timer.new()
		_timer.name = "ReportTimer"
		_timer.wait_time = report_interval
		_timer.autostart = true
		_timer.timeout.connect(_on_report_due)
		add_child(_timer)

	_started = true

	DotLog.info(
		CHANNEL,
		"stats tracker ready",
		{
			"stats": schema.size(),
			"published": schema.published().size(),
			"reporting": report_to_backbone,
			"store": store != null,
		}
	)

	return DotResult.success(self)


func _exit_tree() -> void:
	if not _started or (not report_to_backbone and store == null):
		return
	_checkpoint_all()
	if store != null:
		# Awaited, like the reporter's: a server that stops between flushes does not lose
		# the last interval of everybody's lifetime totals either.
		await flush_store()
	if report_to_backbone and reporter.queued() > 0:
		# A final, awaited flush so a server that stops between reports does not
		# lose the last interval of every player's play.
		await reporter.flush_all()


# --- Players ----------------------------------------------------------------

## Starts counting for a player. Idempotent; a second call updates the name.
func begin(player_id: StringName, player_name: String = "") -> void:
	if _players.has(player_id):
		(_players[player_id] as Dictionary)["name"] = player_name
		return
	_players[player_id] = {
		"name": player_name,
		"session": DotStatsValues.new(),
		"delta": DotStatsValues.new(),
	}


## Stops counting for a player: their outstanding delta is queued and they are
## forgotten. Returns the session set, for a "match summary".
func end(player_id: StringName) -> DotStatsValues:
	if not _players.has(player_id):
		return DotStatsValues.new()
	var row: Dictionary = _players[player_id]
	_checkpoint(player_id, row)
	_players.erase(player_id)
	return row["session"]


func has_player(player_id: StringName) -> bool:
	return _players.has(player_id)


func players() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _players:
		out.append(id)
	return out


## The player's session values so far. Empty for an unknown player.
func session_values(player_id: StringName) -> DotStatsValues:
	if not _players.has(player_id):
		return DotStatsValues.new()
	return (_players[player_id] as Dictionary)["session"]


# --- Recording --------------------------------------------------------------

## Applies a reading to a player's session and delta, by the stat's kind.
##
## [param value] defaults to one, which is what a counter usually wants. A
## player not begun is begun with no name, so a game that only ever calls this
## still works; naming them is what [method begin] is for.
func record(player_id: StringName, stat_id: StringName, value: float = 1.0) -> DotResult:
	if not _started:
		var s := start()
		if not s.ok:
			return s

	var def := schema.find(stat_id)
	if def == null:
		refused.emit(player_id, stat_id, "undeclared")
		return DotResult.fail(
			DotError.CODE_INVALID, "No such stat is declared.", String(stat_id)
		)

	if not _players.has(player_id):
		begin(player_id)

	var row: Dictionary = _players[player_id]
	var session: DotStatsValues = row["session"]
	var delta: DotStatsValues = row["delta"]

	var applied := session.record(def, value)
	if not applied.ok:
		refused.emit(player_id, stat_id, applied.code())
		return applied
	delta.record(def, value)

	recorded.emit(player_id, stat_id, float(applied.value))
	return applied


# --- Reporting --------------------------------------------------------------

## Moves every player's delta into the reporter's queue, then flushes.
##
## What the timer calls. Callable directly at a round end so the board on the
## site moves when the round does rather than up to an interval later.
##
## With a [member store], the same deltas are written to it first. The result is the
## reporter's when reporting is on and the store's when only the store is; the store's is
## also emitted as [signal stored].
func flush() -> DotResult:
	if not report_to_backbone:
		if store == null:
			return DotResult.success(0)
		_checkpoint_all()
		return await flush_store()

	if define_on_start and not _defined and reporter.is_available():
		var defined := await reporter.define()
		if defined.ok:
			_defined = true
		else:
			# Filing still works against stats the site already knows; a define
			# that failed is retried on the next flush, and said so once.
			DotLog.warn(
				CHANNEL,
				"could not declare the stats schema; will retry",
				{"why": defined.error.message}
			)

	_checkpoint_all()
	if store != null:
		await flush_store()
	var res := await reporter.flush_all()
	reported.emit(res)
	return res


func _checkpoint_all() -> void:
	for id in _players:
		_checkpoint(id, _players[id])


## Queues a player's delta and clears it. Does nothing for an empty delta.
func _checkpoint(player_id: StringName, row: Dictionary) -> void:
	var delta: DotStatsValues = row["delta"]
	if delta.is_empty():
		return
	if store != null:
		# The same delta the reporter is about to be handed, at the same moment, so the
		# store and the backbone are told of exactly the same readings.
		_pend_for_store(player_id, str(row["name"]), delta)
	if not report_to_backbone:
		# Reporting off queues NOTHING and says nothing. Until 2026-09-25 a player leaving
		# ([method end]) still pushed their delta into a queue no flush would ever send,
		# and the reporter warned "will not be reported why=unpublished" for every
		# unpublished stat — a WRN on every leave of every server that had simply
		# switched reporting off, which is the default. Cleared so it cannot grow.
		delta.clear()
		return
	var queued := reporter.queue(player_id, str(row["name"]), delta.to_dictionary())
	if not queued.ok:
		DotLog.warn(
			CHANNEL,
			"a player's stats could not be queued",
			{"player": String(player_id).substr(0, 12), "why": queued.error.message}
		)
	delta.clear()


## Writes every checkpointed delta to [member store]. Returns how many players were written.
##
## [b]A failed write keeps what did not land[/b], like the reporter's queue: a store that is
## down for ten minutes costs ten minutes of latency, not ten minutes of totals. What did not
## land is the store's [code]error.context["unapplied"][/code] when it says, and the whole
## delta when it does not.
##
## [b]Taken out before the write and put back UNDER anything newer.[/b] A player keeps
## playing while their write is in flight, and a newer checkpoint lands in the pending set
## meanwhile. Putting the failed older one back on top of it would hand a gauge its older
## reading; folding the newer one into the older keeps the order the readings happened in,
## for every kind. One write runs at a time; a second call while one is in flight returns
## and leaves its players for the next.
func flush_store() -> DotResult:
	if store == null or _store_pending.is_empty() or _store_writing:
		return DotResult.success(0)

	_store_writing = true
	var written := 0
	var failure: DotResult = null

	for player_id in _store_pending.keys():
		var row: Dictionary = _store_pending[player_id]
		_store_pending.erase(player_id)

		var res: DotResult = await store.merge(player_id, row["values"], schema, str(row["name"]))
		if res != null and res.ok:
			written += 1
			continue

		failure = res if res != null else DotResult.fail(DotError.CODE_INTERNAL, "A stats store returned nothing.")
		var unapplied: DotStatsValues = row["values"]
		if failure.error != null and failure.error.context.get("unapplied") is Dictionary:
			unapplied = DotStatsValues.from_dictionary(failure.error.context["unapplied"])
		_restore_for_store(player_id, str(row["name"]), unapplied)
		# A store that failed one player is very likely down for the next; the rest wait
		# for the next flush rather than each failing in turn.
		break

	_store_writing = false

	var result := failure if failure != null else DotResult.success(written)
	if failure != null:
		# WARN on the first failure and DEBUG while it lasts: nothing is lost yet, and a
		# store that is down for an hour would otherwise bury the line that said so.
		var fields := {"why": failure.error.message if failure.error != null else "", "players": _store_pending.size()}
		if _store_failing:
			DotLog.debug(CHANNEL, "lifetime stats still not saving", fields)
		else:
			DotLog.warn(CHANNEL, "lifetime stats are not saving; they will be retried", fields)
		_store_failing = true
	elif _store_failing and written > 0:
		_store_failing = false
		DotLog.info(CHANNEL, "lifetime stats are saving again", {"players": written})

	stored.emit(result)
	return result


## How many players have deltas waiting for [member store].
func store_pending() -> int:
	return _store_pending.size()


func _pend_for_store(player_id: StringName, player_name: String, delta: DotStatsValues) -> void:
	if not _store_pending.has(player_id):
		_store_pending[player_id] = {"name": player_name, "values": DotStatsValues.new()}
	var row: Dictionary = _store_pending[player_id]
	if player_name != "":
		row["name"] = player_name
	(row["values"] as DotStatsValues).merge_from(delta, schema)


## Puts back a write that failed, with anything checkpointed since folded in ON TOP of it.
func _restore_for_store(player_id: StringName, player_name: String, older: DotStatsValues) -> void:
	var restored := older.duplicate_values()
	var newer: Variant = _store_pending.get(player_id)
	if newer is Dictionary:
		restored.merge_from((newer as Dictionary)["values"], schema)
		if str((newer as Dictionary)["name"]) != "":
			player_name = str((newer as Dictionary)["name"])
	_store_pending[player_id] = {"name": player_name, "values": restored}


func _on_report_due() -> void:
	await flush()


func describe() -> Dictionary:
	return {
		"players": _players.size(),
		"schema": schema.describe() if schema != null else null,
		"reporting": report_to_backbone,
		"interval": report_interval,
		"defined": _defined,
		"reporter": reporter.describe(),
		"store": store.describe() if store != null and store.has_method("describe") else null,
		"store_pending": _store_pending.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-12s %s" % [str(k), str(d[k])])
	return out
