extends Node

## Exercises dot-stats without a backbone.
##
## The backbone client is faked one level above HTTP — the untyped
## `post_integration` seam is the whole point of it — so every check here is
## about what this addon promises: that a reading merges by its kind, that a
## reporter never loses what it was given, and that an account id never leaves
## the process as a player.
##
## [codeblock]
## godot --headless --path . res://examples/stats_selftest.tscn
## [/codeblock]

var _passed := 0
var _failed := 0


## A stand-in for dot-auth's DotBackboneClient, which this addon never names.
class FakeBackbone extends RefCounted:
	var calls: Array[Dictionary] = []
	var fail: bool = false
	var status: int = 500

	func post_integration(path: String, body: Dictionary) -> DotResult:
		calls.append({"path": path, "body": body.duplicate(true)})
		if fail:
			var error := DotError.make(DotError.CODE_HTTP, "backbone is down")
			error.http_status = status
			return DotResult.failure(error)
		return DotResult.success({"ok": true})

	func get_integration(path: String, query: Dictionary) -> DotResult:
		calls.append({"path": path, "query": query.duplicate(true)})
		if fail:
			var error := DotError.make(DotError.CODE_HTTP, "backbone is down")
			error.http_status = status
			return DotResult.failure(error)
		if path == DotStatsReporter.PLAYER_PATH:
			return DotResult.success({
				"ok": true, "player": str(query["player"]), "name": "Ada",
				"stats": [{"key": "kills", "kind": "COUNTER", "value": 412.0}],
			})
		return DotResult.success({
			"ok": true, "stat": {"key": str(query["stat"])},
			"rows": [{"rank": 1, "player": "p1", "value": 9130.0}],
			"self": {"rank": 37} if query.has("player") else null,
		})


## A stand-in for dot-auth's DotAuthClient, the player's own token.
class FakeApp extends RefCounted:
	var calls: Array[Dictionary] = []
	var fail: bool = false

	func post_app(path: String, body: Dictionary) -> DotResult:
		calls.append({"path": path, "body": body.duplicate(true)})
		if fail:
			return DotResult.fail(DotError.CODE_HTTP, "no network")
		return DotResult.success({"players": 1, "readings": (body["stats"] as Dictionary).size()})

	func get_app(path: String, query: Dictionary) -> DotResult:
		calls.append({"path": path, "query": query.duplicate(true)})
		return DotResult.success({"player": "me", "stats": []})


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	_line("dot-stats self-test")
	_line("")

	_test_kinds()
	_test_schema()
	_test_values()
	await _test_tracker()
	await _test_reporter_coalesces()
	await _test_reporter_keeps_its_queue()
	_test_reporter_bounds_its_queue()
	_test_reporter_refuses_account_ids()
	await _test_reporter_define()
	await _test_tracker_reports_on_leave()
	await _test_reporter_reads()
	await _test_client()

	_line("")
	_line("%d passed, %d failed" % [_passed, _failed])
	_finish()


# --- Kinds ------------------------------------------------------------------

func _test_kinds() -> void:
	_line("kinds")

	var counter := DotStatsDef.make(&"kills", DotStatsDef.Kind.COUNTER)
	var gauge := DotStatsDef.make(&"level", DotStatsDef.Kind.GAUGE)
	var best := DotStatsDef.make(&"top_speed", DotStatsDef.Kind.BEST)
	var lowest := DotStatsDef.make(&"best_lap", DotStatsDef.Kind.LOWEST)

	_check("a counter adds", counter.merge(3.0, 4.0) == 7.0)
	_check("a gauge takes the newest", gauge.merge(3.0, 4.0) == 4.0 and gauge.merge(4.0, 3.0) == 3.0)
	_check("a best keeps the higher", best.merge(3.0, 4.0) == 4.0 and best.merge(4.0, 3.0) == 4.0)
	_check("a lowest keeps the lower", lowest.merge(3.0, 4.0) == 3.0 and lowest.merge(4.0, 3.0) == 3.0)

	# The first reading of anything is that reading — including a counter,
	# whose first submission is its first total, and a lowest, which must not
	# be compared against an implicit zero it can never beat.
	_check("a first reading stands", lowest.merge(0.0, 42.0, false) == 42.0 and counter.merge(0.0, 5.0, false) == 5.0)

	_check("kind names round-trip", DotStatsDef.kind_from_name("best") == DotStatsDef.Kind.BEST)
	_check("an unknown kind is refused", DotStatsDef.kind_from_name("median") < 0)

	best.unit = "m/s"
	best.decimals = 1
	_check("a value formats with its unit", best.format_value(41.26) == "41.3 m/s")

	_line("")


# --- Schema -----------------------------------------------------------------

func _test_schema() -> void:
	_line("schema")

	var schema := DotStatsSchema.new()
	schema.define(&"kills")
	schema.define(&"deaths")
	schema.define(&"top_speed", DotStatsDef.Kind.BEST, "Top speed").publish = true

	_check("a schema validates", schema.validate().ok)
	_check("a stat is found by id", schema.find(&"deaths") != null)
	_check("and a missing one is null", schema.find(&"assists") == null)
	_check("published() is the published subset", schema.published().size() == 1)

	schema.define(&"kills")
	_check("a duplicate id is refused", not schema.validate().ok)
	schema.stats.pop_back()

	schema.define(&"no spaces allowed")
	_check("a malformed id is refused", not schema.validate().ok)
	schema.stats.pop_back()

	# Round trip through the wire shape, which is also the JSON file shape.
	var parsed := DotStatsSchema.from_dictionary(schema.to_dictionary())
	_check("a schema round-trips", parsed.ok and (parsed.value as DotStatsSchema).size() == 3)
	if parsed.ok:
		var back := parsed.value as DotStatsSchema
		_check("with kinds intact", back.find(&"top_speed").kind == DotStatsDef.Kind.BEST)
		_check("and publish flags intact", back.find(&"top_speed").publish and not back.find(&"kills").publish)

	var bad := DotStatsSchema.from_dictionary({"stats": [{"id": "x", "kind": "median"}]})
	_check("an unknown kind in a file is refused", not bad.ok)

	var many := DotStatsSchema.new()
	for i in range(DotStatsSchema.MAX_STATS + 1):
		many.define(StringName("s%d" % i))
	var capped := many.validate()
	_check("the cap refuses one too many", not capped.ok and capped.code() == DotError.CODE_QUOTA)

	_line("")


# --- Values -----------------------------------------------------------------

func _test_values() -> void:
	_line("values")

	var schema := DotStatsSchema.new()
	var kills := schema.define(&"kills")
	var speed := schema.define(&"top_speed", DotStatsDef.Kind.BEST)

	var v := DotStatsValues.new()
	v.record(kills, 1.0)
	v.record(kills, 1.0)
	v.record(speed, 30.0)
	v.record(speed, 25.0)
	_check("readings merge by kind", v.get_value(&"kills") == 2.0 and v.get_value(&"top_speed") == 30.0)

	var nan := v.record(kills, NAN)
	_check("a NaN reading is refused", not nan.ok and v.get_value(&"kills") == 2.0)
	var inf := v.record(speed, INF)
	_check("and so is an infinite one", not inf.ok and v.get_value(&"top_speed") == 30.0)

	var other := DotStatsValues.new()
	other.record(kills, 3.0)
	other.record(speed, 28.0)
	other.values[&"unknown"] = 9.0
	v.merge_from(other, schema)
	_check("a merge is a walk by the same rules", v.get_value(&"kills") == 5.0 and v.get_value(&"top_speed") == 30.0)
	_check("and skips what the schema does not know", not v.has(&"unknown"))

	var read := DotStatsValues.from_dictionary({"kills": 4, "top_speed": 12.5, "name": "banana"})
	_check("a dictionary reads numerics only", read.size() == 2 and read.get_value(&"kills") == 4.0)

	_line("")


# --- Tracker ----------------------------------------------------------------

func _make_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()
	schema.define(&"kills").publish = true
	schema.define(&"deaths").publish = true
	schema.define(&"top_speed", DotStatsDef.Kind.BEST).publish = true
	schema.define(&"level", DotStatsDef.Kind.GAUGE).publish = true
	schema.define(&"secret")   # kept, never reported
	return schema


func _test_tracker() -> void:
	_line("tracker")

	var tracker := DotStatsTracker.new()
	tracker.name = "Tracker"
	tracker.schema = _make_schema()
	tracker.report_to_backbone = false
	add_child(tracker)

	_check("the tracker starts", tracker.start().ok)

	# A GDScript lambda captures by value, so a counter incremented inside one
	# stays zero outside it. An Array is a reference and is appended instead.
	var seen: Array = []
	tracker.recorded.connect(func(_p: StringName, s: StringName, v: float) -> void:
		seen.append([s, v]))

	tracker.begin(&"p1", "Ada")
	tracker.record(&"p1", &"kills")
	tracker.record(&"p1", &"kills")
	tracker.record(&"p1", &"top_speed", 30.0)
	tracker.record(&"p1", &"top_speed", 20.0)
	tracker.record(&"p1", &"level", 3.0)
	tracker.record(&"p1", &"level", 4.0)

	var session := tracker.session_values(&"p1")
	_check(
		"a session accumulates by kind",
		session.get_value(&"kills") == 2.0
			and session.get_value(&"top_speed") == 30.0
			and session.get_value(&"level") == 4.0
	)
	_check("and each reading is signalled", seen.size() == 6)

	var undeclared := tracker.record(&"p1", &"assists")
	_check("an undeclared stat is refused", not undeclared.ok)

	tracker.record(&"p2", &"deaths", 1.0)
	_check("a player not begun is begun", tracker.has_player(&"p2"))

	var summary := tracker.end(&"p1")
	_check("ending returns the session", summary.get_value(&"kills") == 2.0)
	_check("and forgets the player", not tracker.has_player(&"p1"))

	_check("describe() answers", tracker.describe().has("players"))

	tracker.queue_free()
	_line("")


# --- Reporter ---------------------------------------------------------------

func _test_reporter_coalesces() -> void:
	_line("reporter coalesces")

	var backbone := FakeBackbone.new()
	var reporter := DotStatsReporter.with_client(backbone, _make_schema())

	reporter.queue(&"p1", "Ada", {"kills": 3, "top_speed": 30.0, "level": 3})
	reporter.queue(&"p1", "Ada", {"kills": 4, "top_speed": 20.0, "level": 5})
	reporter.queue(&"p2", "Bob", {"deaths": 1})

	_check("two readings of one player are one row", reporter.queued() == 2)

	var res := await reporter.flush()
	_check("a flush succeeds", res.ok and int(res.value) == 2, res)
	_check("and empties the queue", reporter.queued() == 0)

	var body: Dictionary = backbone.calls[0]["body"]
	var players: Array = body["players"]
	var ada: Dictionary = players[0]
	var stats: Dictionary = ada["stats"]
	_check("the batch goes to stats/submit", str(backbone.calls[0]["path"]) == DotStatsReporter.SUBMIT_PATH)
	_check(
		"coalesced by kind: counter summed, best kept, gauge newest",
		float(stats["kills"]) == 7.0 and float(stats["top_speed"]) == 30.0 and float(stats["level"]) == 5.0
	)
	_check("the row names the player", str(ada["player"]) == "p1" and str(ada["name"]) == "Ada")

	# What is not published does not leave.
	reporter.queue(&"p3", "Eve", {"secret": 1, "nope": 2})
	_check("unpublished and unknown stats queue nothing", reporter.queued() == 0)

	_line("")


func _test_reporter_keeps_its_queue() -> void:
	_line("reporter keeps its queue")

	var backbone := FakeBackbone.new()
	var reporter := DotStatsReporter.with_client(backbone, _make_schema())

	for i in range(5):
		reporter.queue(StringName("p%d" % i), "P", {"kills": 1})

	backbone.fail = true
	var failed := await reporter.flush()
	_check("a failed flush reports failure", not failed.ok)
	_check("and the queue is intact", reporter.queued() == 5)
	_check("and counted", reporter.failures == 1)

	backbone.fail = false
	var ok := await reporter.flush()
	_check("the next flush sends it all", ok.ok and int(ok.value) == 5, ok)
	_check("in one request", backbone.calls.size() == 2 and (backbone.calls[1]["body"]["players"] as Array).size() == 5)

	# A forbidden is not retried in the log's face, but it is not lost either.
	reporter.queue(&"p9", "P", {"kills": 1})
	backbone.fail = true
	backbone.status = 403
	var forbidden := await reporter.flush()
	_check("a 403 keeps the queue too", not forbidden.ok and reporter.queued() == 1)

	var without := DotStatsReporter.new()
	without.schema = _make_schema()
	without.queue(&"p1", "P", {"kills": 1})
	var none := await without.flush()
	_check("no client is a state error, not a crash", not none.ok and none.code() == DotError.CODE_STATE)

	_line("")


func _test_reporter_bounds_its_queue() -> void:
	_line("reporter bounds its queue")

	var reporter := DotStatsReporter.with_client(FakeBackbone.new(), _make_schema())
	reporter.player_limit = 10

	for i in range(40):
		reporter.queue(StringName("p%d" % i), "P", {"kills": i})

	_check("the queue holds the limit", reporter.queued() == 10)
	_check("and counts what it dropped", reporter.dropped == 30)
	_check("keeping the newest", reporter._queue.has(&"p39") and not reporter._queue.has(&"p0"))

	# A player who keeps scoring is moved to the newest end, so an active
	# player is not the one dropped.
	reporter.queue(&"p30", "P", {"kills": 1})
	reporter.queue(&"p99", "P", {"kills": 1})
	_check("an active player survives the trim", reporter._queue.has(&"p30") and not reporter._queue.has(&"p31"))

	_line("")


func _test_reporter_refuses_account_ids() -> void:
	_line("reporter refuses account ids")

	var reporter := DotStatsReporter.with_client(FakeBackbone.new(), _make_schema())

	var account := reporter.queue(&"backbone:clx8f2k0000", "Ada", {"kills": 1})
	_check(
		"a dot-auth account uid is refused as a player",
		not account.ok and account.code() == DotError.CODE_INVALID and reporter.queued() == 0
	)

	var scoped := reporter.queue(&"Qx3v_9LkP2mR8sT1uVwXyZ", "Ada", {"kills": 1})
	_check("a scoped key is accepted", scoped.ok and reporter.queued() == 1)

	_check("an empty id is not a player", not DotStatsReporter.is_player_id(""))

	_line("")


func _test_reporter_define() -> void:
	_line("reporter declares")

	var backbone := FakeBackbone.new()
	var reporter := DotStatsReporter.with_client(backbone, _make_schema())

	var defined := await reporter.define()
	_check("define() posts the published stats", defined.ok, defined)
	if not backbone.calls.is_empty():
		var body: Dictionary = backbone.calls[0]["body"]
		var list: Array = body["stats"]
		_check("to stats/define", str(backbone.calls[0]["path"]) == DotStatsReporter.DEFINE_PATH)
		_check("only the published ones", list.size() == 4)
		var first: Dictionary = list[0]
		# StatsDefineInput's shape: `key`, never `id` — the site's comment on the
		# field says as much and this once sent `id` anyway.
		_check("with the wire shape", first.has("key") and not first.has("id") and first.has("kind") and first.has("unit") and first.has("decimals"))
		_check("and the kind by name", first["kind"] is String)

	var quiet := DotStatsReporter.with_client(backbone, DotStatsSchema.new())
	quiet.schema.define(&"private")
	var nothing := await quiet.define()
	_check("nothing published is nothing to declare", not nothing.ok and nothing.code() == DotError.CODE_STATE)

	_line("")


# --- The whole loop ---------------------------------------------------------

func _test_tracker_reports_on_leave() -> void:
	_line("tracker reports")

	var backbone := FakeBackbone.new()
	var tracker := DotStatsTracker.new()
	tracker.name = "ReportingTracker"
	tracker.schema = _make_schema()
	tracker.report_to_backbone = true
	tracker.report_interval = 0.0
	tracker.reporter.client = backbone
	add_child(tracker)

	tracker.begin(&"p1", "Ada")
	tracker.record(&"p1", &"kills")
	tracker.record(&"p1", &"kills")
	tracker.record(&"p1", &"secret", 5.0)

	var first := await tracker.flush()
	_check("a flush declares first, then files", first.ok and backbone.calls.size() == 2, first)
	if backbone.calls.size() == 2:
		_check("define before submit", str(backbone.calls[0]["path"]) == DotStatsReporter.DEFINE_PATH)
		var stats: Dictionary = (backbone.calls[1]["body"]["players"] as Array)[0]["stats"]
		_check("the delta is what was counted", float(stats["kills"]) == 2.0)
		_check("and the unpublished stat stayed home", not stats.has("secret"))

	# Deltas, not totals: the next flush carries only what happened since.
	tracker.record(&"p1", &"kills")
	await tracker.flush()
	var second_stats: Dictionary = (backbone.calls[2]["body"]["players"] as Array)[0]["stats"]
	_check("the next flush is a delta", float(second_stats["kills"]) == 1.0)
	_check("while the session is the total", tracker.session_values(&"p1").get_value(&"kills") == 3.0)

	# Nothing happened: nothing is sent.
	var idle := await tracker.flush()
	_check("an idle flush sends nothing", idle.ok and backbone.calls.size() == 3)
	_check("declared once", tracker.describe()["defined"] == true)

	# A player leaving is reported on the next flush, not lost.
	tracker.record(&"p1", &"deaths")
	tracker.end(&"p1")
	_check("leaving queues the last delta", tracker.reporter.queued() == 1)
	await tracker.flush()
	var last: Dictionary = (backbone.calls[3]["body"]["players"] as Array)[0]["stats"]
	_check("and it is sent", float(last["deaths"]) == 1.0)

	tracker.queue_free()
	_line("")


# --- Helpers ----------------------------------------------------------------

func _check(what: String, passed: bool, res: DotResult = null) -> void:
	if passed:
		_passed += 1
		_line("  %-48s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s" % res.error.message
	_line("  %-48s FAILED%s" % [what, why])


func _finish() -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(1 if _failed > 0 else 0)


func _line(text: String) -> void:
	print(text)


# --- Reading ----------------------------------------------------------------

func _test_reporter_reads() -> void:
	_line("reporter reads")

	var backbone := FakeBackbone.new()
	var reporter := DotStatsReporter.with_client(backbone, _make_schema())

	var mine := await reporter.fetch_player(&"p1")
	_check("fetch_player asks stats/player", mine.ok and str(backbone.calls[0]["path"]) == DotStatsReporter.PLAYER_PATH, mine)
	_check("for that player", str(backbone.calls[0]["query"]["player"]) == "p1")
	_check("and returns the reply", mine.ok and (mine.value["stats"] as Array).size() == 1)

	var top := await reporter.fetch_top(&"kills", 10, 0, &"p2")
	_check("fetch_top asks stats/top", top.ok and str(backbone.calls[1]["path"]) == DotStatsReporter.TOP_PATH, top)
	var q: Dictionary = backbone.calls[1]["query"]
	_check("with the stat, the page and the player", str(q["stat"]) == "kills" and int(q["limit"]) == 10 and str(q["player"]) == "p2")
	_check("and self comes back", top.ok and top.value["self"] != null)

	var anon := await reporter.fetch_top(&"kills")
	_check("no player means no self", anon.ok and anon.value["self"] == null)

	var without := DotStatsReporter.new()
	without.schema = _make_schema()
	var none := await without.fetch_player(&"p1")
	_check("no client is a state error", not none.ok and none.code() == DotError.CODE_STATE)

	_line("")


# --- The player's own client ------------------------------------------------

func _test_client() -> void:
	_line("client")

	var app := FakeApp.new()
	var mine := DotStatsClient.new()
	mine.name = "MyStats"
	mine.schema = _make_schema()
	mine.report_interval = 0.0
	mine.client = app
	add_child(mine)

	_check("the client starts", mine.start().ok)

	mine.record(&"kills")
	mine.record(&"kills")
	mine.record(&"top_speed", 30.0)
	mine.record(&"top_speed", 20.0)
	mine.record(&"secret", 5.0)

	_check("readings coalesce by kind", mine.session_values().get_value(&"kills") == 2.0 and mine.session_values().get_value(&"top_speed") == 30.0)
	_check("the unpublished one is kept but not pending", mine.session_values().has(&"secret") and mine.pending() == 2)

	var undeclared := mine.record(&"assists")
	_check("an undeclared stat is refused", not undeclared.ok)

	var flushed := await mine.flush()
	_check("a flush posts to stats/submit", flushed.ok and str(app.calls[0]["path"]) == DotStatsClient.SUBMIT_PATH, flushed)
	var body: Dictionary = app.calls[0]["body"]
	_check("with the delta and no app when the token decides", float(body["stats"]["kills"]) == 2.0 and not body.has("app"))
	_check("and clears the delta", mine.pending() == 0)

	mine.app_id = 12
	mine.record(&"kills")
	app.fail = true
	var kept := await mine.flush()
	_check("a failed flush keeps the delta", not kept.ok and mine.pending() == 1)
	app.fail = false
	await mine.flush()
	_check("a device build names its app", int(app.calls[2]["body"]["app"]) == 12)

	var got := await mine.fetch_mine()
	_check("fetch_mine asks stats/me for the app", got.ok and str(app.calls[3]["path"]) == DotStatsClient.MINE_PATH and int(app.calls[3]["query"]["app"]) == 12, got)

	var top := await mine.fetch_top(&"kills", 5)
	_check("fetch_top asks stats/top", top.ok and str(app.calls[4]["path"]) == DotStatsClient.TOP_PATH and int(app.calls[4]["query"]["limit"]) == 5)

	var idle := await mine.flush()
	_check("an idle flush sends nothing", idle.ok and app.calls.size() == 5)

	mine.queue_free()
	_line("")
