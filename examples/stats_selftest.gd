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

const CHECKS := 138

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 15

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


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
	await _test_memory_store()
	await _test_tracker_store()
	await _test_sql_store()

	_line("")
	_line("%d passed, %d failed" % [_passed, _failed])
	_finish()


# --- Kinds ------------------------------------------------------------------

func _test_kinds() -> void:
	_section("kinds")

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
	_done()


# --- Schema -----------------------------------------------------------------

func _test_schema() -> void:
	_section("schema")

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
	_done()


# --- Values -----------------------------------------------------------------

func _test_values() -> void:
	_section("values")

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
	_done()


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
	_section("tracker")

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

	# An unpublished stat, which is what the reporter warns about when it is queued.
	tracker.record(&"p1", &"secret", 5.0)
	var summary := tracker.end(&"p1")
	_check("ending returns the session", summary.get_value(&"kills") == 2.0)
	_check("and forgets the player", not tracker.has_player(&"p1"))
	# Reporting is off: a leave queues nothing and warns about nothing. It used to fill a
	# queue no flush would send and log "will not be reported why=unpublished" per leave.
	_check("with reporting off, a leave queues nothing", tracker.reporter.queued() == 0)
	_check(
		"and says nothing about stats it was never going to report",
		(tracker.reporter.get("_warned") as Dictionary).is_empty()
	)

	_check("describe() answers", tracker.describe().has("players"))

	tracker.queue_free()
	_line("")
	_done()


# --- Reporter ---------------------------------------------------------------

func _test_reporter_coalesces() -> void:
	_section("reporter coalesces")

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
	_done()


func _test_reporter_keeps_its_queue() -> void:
	_section("reporter keeps its queue")

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
	_done()


func _test_reporter_bounds_its_queue() -> void:
	_section("reporter bounds its queue")

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
	_done()


func _test_reporter_refuses_account_ids() -> void:
	_section("reporter refuses account ids")

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
	_done()


func _test_reporter_define() -> void:
	_section("reporter declares")

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
	_done()


# --- The whole loop ---------------------------------------------------------

func _test_tracker_reports_on_leave() -> void:
	_section("tracker reports")

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
	_done()


# --- Lifetime stores ----------------------------------------------------------

## Every kind, for the stores. `best_lap` is the LOWEST, which ranks the other way.
func _store_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()
	schema.define(&"kills")
	schema.define(&"level", DotStatsDef.Kind.GAUGE)
	schema.define(&"top_speed", DotStatsDef.Kind.BEST)
	schema.define(&"best_lap", DotStatsDef.Kind.LOWEST)
	return schema


func _test_memory_store() -> void:
	_section("lifetime store, in memory")

	var store := DotStatsStoreMemory.new()
	var no_rules: DotResult = await store.merge(&"p1", {"kills": 1})
	_check("a merge with no schema to merge by is refused", not no_rules.ok and no_rules.code() == DotError.CODE_STATE)

	var schema := _store_schema()
	await store.merge(&"p1", {"kills": 3, "level": 2, "top_speed": 30.0, "best_lap": 12.0}, schema, "Ada")
	var totals: DotResult = await store.merge(&"p1", {"kills": 4, "level": 1, "top_speed": 20.0, "best_lap": 15.0}, schema)
	var v: DotStatsValues = totals.value if totals.ok else DotStatsValues.new()
	_check(
		"each kind merges by its own rule: 3+4 kills, level replaced, best kept, lowest kept",
		v.get_value(&"kills") == 7.0 and v.get_value(&"level") == 1.0
			and v.get_value(&"top_speed") == 30.0 and v.get_value(&"best_lap") == 12.0
	)
	_check(
		"a first LOWEST reading stands, rather than losing to an implicit zero",
		(await store.values_for(&"p1")).value.get_value(&"best_lap") == 12.0
	)

	var odd: DotResult = await store.merge(&"p2", {"kills": NAN, "assists": 4, "name": "x", "top_speed": 41.0}, schema, "Bo")
	_check(
		"a NaN, an undeclared stat and a non-number are left out; the rest lands",
		odd.ok and (odd.value as DotStatsValues).size() == 1 and (odd.value as DotStatsValues).get_value(&"top_speed") == 41.0
	)

	var nobody: DotResult = await store.values_for(&"nobody")
	_check("a player with nothing is an empty set, not null", nobody.ok and (nobody.value as DotStatsValues).is_empty())

	await store.merge(&"p3", {"kills": 7, "best_lap": 10.0}, schema, "Cy")
	await store.merge(&"p4", {"kills": 1, "best_lap": 12.0}, schema, "Di")
	var kills: DotResult = await store.top(&"kills")
	var shape: Array = (kills.value as Array).map(func(r): return "%s=%d" % [r["player"], r["rank"]]) if kills.ok else []
	_check("a counter ranks highest first, a tie sharing its rank", str(shape) == str(["p1=1", "p3=1", "p4=3"]), kills)
	var laps: DotResult = await store.top(&"best_lap", 2)
	var lap_shape: Array = (laps.value as Array).map(func(r): return "%s=%d" % [r["player"], r["rank"]]) if laps.ok else []
	_check("a LOWEST ranks lowest first, and a limit is a limit", str(lap_shape) == str(["p3=1", "p1=2"]), laps)
	_check(
		"a row carries the player's name",
		laps.ok and (laps.value as Array)[0]["name"] == "Cy"
	)

	var unknown: DotResult = await store.top(&"assists")
	_check("a ranking of an undeclared stat is refused, not empty", not unknown.ok and unknown.code() == DotError.CODE_INVALID)

	_check(
		"a rank counts who is strictly ahead; absent is 0",
		(await store.rank_of(&"best_lap", &"p4")).value == 2 and (await store.rank_of(&"best_lap", &"p2")).value == 0
	)

	var removed: DotResult = await store.remove_player(&"p1")
	_check("a player can be forgotten", removed.ok and removed.value == true and (await store.values_for(&"p1")).value.is_empty())

	_line("")
	_done()


## A store that fails on demand, part-way, the way the SQL store reports it.
class FlakyStatsStore extends DotStatsStoreMemory:
	var fail_with_unapplied: Dictionary = {}
	var fail_all: bool = false
	var calls: int = 0

	func _merge(player_id: StringName, incoming: DotStatsValues, p_schema: DotStatsSchema, player_name: String) -> DotResult:
		calls += 1
		if fail_all:
			return DotResult.fail(DotError.CODE_IO, "the database is down")
		if not fail_with_unapplied.is_empty():
			# Apply everything but the unapplied stats, then fail naming them.
			var landed := DotStatsValues.new()
			for id in incoming.values:
				if not fail_with_unapplied.has(String(id)):
					landed.values[id] = incoming.values[id]
			await super(player_id, landed, p_schema, player_name)
			var res := DotResult.fail(DotError.CODE_IO, "lost the connection part-way")
			res.error.context["unapplied"] = fail_with_unapplied.duplicate()
			fail_with_unapplied = {}
			return res
		return await super(player_id, incoming, p_schema, player_name)


func _test_tracker_store() -> void:
	_section("the tracker keeps lifetime totals")

	var store := FlakyStatsStore.new()
	var tracker := DotStatsTracker.new()
	tracker.name = "StoringTracker"
	tracker.schema = _store_schema()
	tracker.report_to_backbone = false
	tracker.report_interval = 0.0
	tracker.store = store
	add_child(tracker)
	tracker.start()
	_check("the tracker hands the store its schema", store.schema == tracker.schema)

	tracker.begin(&"p1", "Ada")
	tracker.record(&"p1", &"kills", 2.0)
	tracker.record(&"p1", &"level", 3.0)
	var first: DotResult = await tracker.flush()
	_check("with no backbone, a flush still writes the store", first.ok and first.value == 1, first)
	_check("and the reporter is never touched", tracker.reporter.queued() == 0)
	_check("the store holds the totals", (await store.values_for(&"p1")).value.get_value(&"kills") == 2.0)

	tracker.record(&"p1", &"kills", 1.0)
	tracker.end(&"p1")
	_check("a leave checkpoints the last delta for the store", tracker.store_pending() == 1)
	await tracker.flush()
	tracker.begin(&"p1", "Ada")
	tracker.record(&"p1", &"kills", 4.0)
	await tracker.flush()
	_check(
		"so a second session adds to the lifetime total: 2 + 1 + 4",
		(await store.values_for(&"p1")).value.get_value(&"kills") == 7.0
	)

	# The store fails part-way: only what did not land is kept, so nothing is counted twice.
	tracker.record(&"p1", &"kills", 5.0)
	tracker.record(&"p1", &"level", 9.0)
	store.fail_with_unapplied = {"level": 9.0}
	var partial: DotResult = await tracker.flush()
	_check("a write that fails part-way is reported", not partial.ok)
	_check("and only what did not land waits", tracker.store_pending() == 1
		and (tracker.get("_store_pending")[&"p1"]["values"] as DotStatsValues).size() == 1)
	await tracker.flush()
	var after: DotStatsValues = (await store.values_for(&"p1")).value
	_check(
		"then lands once: the kills that landed are not added again (7 + 5), and the level arrives",
		after.get_value(&"kills") == 12.0 and after.get_value(&"level") == 9.0
	)

	# A store that is down keeps everything, and a newer reading is folded on TOP of the
	# older one when it comes back — a gauge must end at its newest reading.
	store.fail_all = true
	tracker.record(&"p1", &"level", 10.0)
	await tracker.flush()
	tracker.record(&"p1", &"level", 11.0)
	tracker.record(&"p1", &"kills", 1.0)
	await tracker.flush()
	store.fail_all = false
	await tracker.flush()
	var back: DotStatsValues = (await store.values_for(&"p1")).value
	_check(
		"a store that was down loses nothing, and a gauge ends at its newest reading",
		back.get_value(&"level") == 11.0 and back.get_value(&"kills") == 13.0 and tracker.store_pending() == 0
	)

	tracker.queue_free()

	# Both: the store and the reporter are handed the same deltas.
	var backbone := FakeBackbone.new()
	var both_store := DotStatsStoreMemory.new()
	var both := DotStatsTracker.new()
	both.name = "BothTracker"
	both.schema = _make_schema()
	both.report_to_backbone = true
	both.report_interval = 0.0
	both.reporter.client = backbone
	both.store = both_store
	add_child(both)
	both.record(&"p9", &"kills", 3.0)
	both.record(&"p9", &"secret", 2.0)
	var flushed: DotResult = await both.flush()
	var sent: Dictionary = (backbone.calls[-1]["body"]["players"] as Array)[0]["stats"] if backbone.calls.size() > 1 else {}
	var kept: DotStatsValues = (await both_store.values_for(&"p9")).value
	_check(
		"with both, the backbone and the store are told the same kills",
		flushed.ok and float(sent.get("kills", 0)) == 3.0 and kept.get_value(&"kills") == 3.0
	)
	_check(
		"and an unpublished stat stays home but is still kept",
		not sent.has("secret") and kept.get_value(&"secret") == 2.0
	)
	both.queue_free()

	_line("")
	_done()


## A recording driver whose UPDATEs find no row a set number of times — another server
## writing the row between this one's read and write — and whose INSERTs can fail.
class RacingDriver extends DotSqlDriverRecording:
	var lose_updates: int = 0
	var fail_inserts: int = 0

	func _init(p_dialect: int = DotSqlDialect.Kind.SQLITE) -> void:
		super(p_dialect)

	func _execute(sql: String, params: Array) -> DotResult:
		if sql.begins_with("UPDATE") and lose_updates > 0:
			lose_updates -= 1
			statements.append({"sql": sql, "params": params.duplicate()})
			return DotResult.success(0)
		if sql.begins_with("INSERT INTO dot_stats_values") and fail_inserts > 0:
			fail_inserts -= 1
			statements.append({"sql": sql, "params": params.duplicate()})
			return DotResult.fail(DotError.CODE_IO, "UNIQUE constraint failed")
		return await super(sql, params)


func _test_sql_store() -> void:
	_section("lifetime store in SQL, against a driver that records")

	_check("the table spec is valid", DotSqlSchema.validate(DotStatsSqlSchema.table_spec()).ok)

	var schema := _store_schema()
	var driver := RacingDriver.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotStatsStoreSql.new(driver)
	store.schema = schema

	var closed: DotResult = await store.merge(&"p1", {"kills": 2})
	_check(
		"a store never opened fails, and says the whole delta did not land",
		not closed.ok and closed.code() == DotError.CODE_STATE and closed.error.context.get("unapplied", {}).get("kills") == 2.0
	)

	var opened: DotResult = await store.open()
	_check("the store opens", opened.ok, opened)
	_check(
		"the table, its ranking index and its schema version",
		driver.matching("CREATE TABLE IF NOT EXISTS dot_stats_values").size() == 1
			and driver.matching("CREATE INDEX IF NOT EXISTS dot_stats_values_top_idx").size() == 1
			and driver.matching("INSERT INTO dot_sql_migrations").size() == 1
	)

	# A first merge: a read, then a plain INSERT per stat.
	driver.clear()
	driver.answers = {"SELECT stat, amount, revision": []}
	var first: DotResult = await store.merge(&"p'1", {"kills": 2, "best_lap": 12.5}, schema, "O'Brien")
	var inserts := driver.matching("INSERT INTO dot_stats_values")
	_check("a new player is read, then inserted", first.ok and inserts.size() == 2 and str(driver.statements[0]["sql"]).begins_with("SELECT"), first)
	_check(
		"as a plain INSERT, never an upsert: a row somebody else made must not be overwritten",
		inserts.size() == 2 and not str(inserts[0]["sql"]).contains("ON CONFLICT")
	)
	_check(
		"bound as player, stat, amount, name, revision 0, time",
		inserts.size() == 2 and (inserts[0]["params"] as Array).slice(0, 5) == ["p'1", "kills", 2.0, "O'Brien", 0]
			and not str(inserts[0]["sql"]).contains("O'Brien")
	)

	# An existing row: the rule runs HERE, and the value is written guarded by revision.
	driver.clear()
	driver.answers = {"SELECT stat, amount, revision": [
		{"stat": "kills", "amount": 7.0, "revision": 4.0},
		{"stat": "top_speed", "amount": "30.5", "revision": 1},
		{"stat": "best_lap", "amount": 12.5, "revision": 2},
	]}
	await store.merge(&"p1", {"kills": 3, "top_speed": 20.0, "best_lap": 11.0}, schema, "")
	var updates := driver.matching("UPDATE dot_stats_values")
	_check("a best that was not beaten writes nothing; the others write once each", updates.size() == 2)
	_check(
		"a counter's new total is computed by DotStatsDef.merge and bound: 7 + 3, at revision 4",
		updates.size() == 2 and (updates[0]["params"] as Array)[0] == 10.0
			and (updates[0]["params"] as Array).slice(3) == ["p1", "kills", 4]
	)
	_check(
		"a lowest keeps the lower: 11 over 12.5",
		updates.size() == 2 and (updates[1]["params"] as Array)[0] == 11.0
	)
	_check(
		"and the guard is in the statement",
		updates.size() == 2 and str(updates[0]["sql"]).contains("WHERE player = ? AND stat = ? AND revision = ?")
			and str(updates[0]["sql"]).contains("revision = revision + 1")
	)
	var arithmetic := false
	for statement in driver.statements:
		var text := str(statement["sql"]).to_upper()
		if text.contains("GREATEST") or text.contains("LEAST") or text.contains("AMOUNT +") or text.contains("MAX("):
			arithmetic = true
	_check("no statement re-spells the merge rule in SQL", not arithmetic)

	# Losing the race: the update finds no row, so the merge re-reads and folds again.
	driver.clear()
	driver.lose_updates = 1
	var raced: DotResult = await store.merge(&"p1", {"kills": 1}, schema)
	_check(
		"an update that lost a race is re-read and folded again, not written blind",
		raced.ok and driver.matching("SELECT stat, amount, revision").size() == 3
			and driver.matching("UPDATE dot_stats_values").size() == 2 and store.conflicts == 1,
		raced
	)

	driver.clear()
	driver.lose_updates = 99
	var hopeless: DotResult = await store.merge(&"p1", {"kills": 1}, schema)
	_check(
		"and one that keeps losing gives up as a conflict, naming what did not land",
		not hopeless.ok and hopeless.code() == DotError.CODE_CONFLICT
			and hopeless.error.context.get("unapplied", {}).get("kills") == 1.0
	)
	driver.lose_updates = 0

	# An INSERT that fails while the row is still absent is a real failure, not a race.
	driver.clear()
	driver.answers = {"SELECT stat, amount, revision": []}
	driver.fail_inserts = 2
	var refused: DotResult = await store.merge(&"p5", {"kills": 1, "level": 3}, schema)
	_check(
		"an insert that fails with no row behind it is a failure, with both stats unapplied",
		not refused.ok and driver.matching("SELECT stat, amount, revision").size() == 2
			and (refused.error.context.get("unapplied", {}) as Dictionary).size() == 2,
		refused
	)
	driver.fail_inserts = 0

	driver.clear()
	driver.fail_next = "connection reset"
	var failed: DotResult = await store.merge(&"p1", {"kills": 1}, schema)
	_check("a read failure fails the merge", not failed.ok and failed.error.context.has("unapplied"))

	# Rankings.
	driver.clear()
	driver.answers = {"AS place": [
		{"player": "p3", "player_name": "Cy", "amount": 10.0, "place": 1.0},
		{"player": "p1", "player_name": null, "amount": "12.5", "place": 2},
	]}
	var laps: DotResult = await store.top(&"best_lap", 2, 4)
	var lap_sql := str(driver.statements[0]["sql"]) if driver.statements.size() == 1 else ""
	_check(
		"a LOWEST ranks ascending and counts the lower amounts as ahead",
		lap_sql.contains("ORDER BY s.amount ASC") and lap_sql.contains("b.amount < s.amount")
	)
	_check(
		"bound as stat, LIMIT, OFFSET",
		driver.statements.size() == 1 and (driver.statements[0]["params"] as Array) == ["best_lap", 2, 4]
	)
	_check(
		"rows map back: rank, value from text, a NULL name as empty",
		laps.ok and (laps.value as Array).size() == 2 and (laps.value as Array)[1]["rank"] == 2
			and (laps.value as Array)[1]["value"] == 12.5 and (laps.value as Array)[1]["name"] == ""
	)
	driver.clear()
	await store.top(&"kills")
	_check(
		"a counter ranks descending",
		driver.statements.size() == 1 and str(driver.statements[0]["sql"]).contains("ORDER BY s.amount DESC")
	)
	var undeclared: DotResult = await store.top(&"assists")
	_check("an undeclared stat is refused before any statement", not undeclared.ok and driver.statements.size() == 1)

	driver.clear()
	driver.answers = {"AS place": [{"place": 3.0}]}
	var rank: DotResult = await store.rank_of(&"kills", &"p1")
	driver.answers = {"AS place": []}
	var none: DotResult = await store.rank_of(&"kills", &"nobody")
	_check("a rank comes back an int, and an absent player is 0", rank.ok and rank.value == 3 and none.ok and none.value == 0)

	var newer := DotSqlDriverRecording.new(DotSqlDialect.Kind.SQLITE)
	newer.answers = {"SELECT version FROM": [{"version": 99}]}
	var refused_open: DotResult = await DotStatsStoreSql.new(newer).open()
	_check(
		"a database from a newer build is refused, and nothing is created in it",
		not refused_open.ok and newer.matching("CREATE TABLE IF NOT EXISTS dot_stats_values").is_empty()
	)

	_line("")
	_done()


# --- Helpers ----------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


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
	if not DotPlatform.is_headless():
		return

	await get_tree().process_frame

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and a counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _line(text: String) -> void:
	print(text)


# --- Reading ----------------------------------------------------------------

func _test_reporter_reads() -> void:
	_section("reporter reads")

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
	_done()


# --- The player's own client ------------------------------------------------

func _test_client() -> void:
	_section("client")

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
	_done()
