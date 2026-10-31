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

const CHECKS := 247

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 21

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
	_test_v2_declarations()
	_test_cells_and_events()
	await _test_batch_ids()
	await _test_v2_submit()
	await _test_site_contract()
	await _test_kills()

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

	var lazy := DotStatsReporter.new()
	lazy.schema = _make_schema()
	lazy.client_service = &"stats_selftest_client"
	_check("no client and none registered is unavailable", not lazy.is_available())
	var fake := FakeBackbone.new()
	DotRegistry.register(&"stats_selftest_client", fake)
	_check("a client is found by service name", lazy.is_available() and lazy.client == fake)
	DotRegistry.unregister_instance(&"stats_selftest_client", fake)

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
		driver.matching("CREATE TABLE IF NOT EXISTS dot_stats_values (").size() == 1
			and driver.matching("CREATE INDEX IF NOT EXISTS dot_stats_values_top_idx").size() == 1
			and driver.matching("INSERT INTO dot_sql_migrations").size() == 3
	)
	_check(
		"the ranking index is renamed: new created, legacy dropped",
		driver.matching("CREATE INDEX IF NOT EXISTS dot_stats_values_stat_dim_amount_idx ON dot_stats_values").size() == 1
			and driver.matching("DROP INDEX IF EXISTS dot_stats_values_dim_top_dim_idx").size() == 1
	)
	var my := DotStatsSqlSchema.rank_index_statements("t", "t_dim_top_dim_idx", true)
	_check("MySQL drops an index with ON <table>", my[1] == "DROP INDEX t_dim_top_dim_idx ON t")

	_check(
		"the dim upgrade copies rows into a keyed-by-dim table and swaps it in",
		driver.matching("CREATE TABLE IF NOT EXISTS dot_stats_values_dim").size() == 1
			and driver.matching("SELECT player, stat, '', amount").size() == 1
			and driver.matching("DROP TABLE dot_stats_values").size() == 1
			and driver.matching("RENAME TO dot_stats_values").size() == 1
	)

	# A first merge: a read, then a plain INSERT per stat.
	driver.clear()
	driver.answers = {"SELECT stat, dim, amount, revision": []}
	var first: DotResult = await store.merge(&"p'1", {"kills": 2, "best_lap": 12.5}, schema, "O'Brien")
	var inserts := driver.matching("INSERT INTO dot_stats_values")
	_check("a new player is read, then inserted", first.ok and inserts.size() == 2 and str(driver.statements[0]["sql"]).begins_with("SELECT"), first)
	_check(
		"as a plain INSERT, never an upsert: a row somebody else made must not be overwritten",
		inserts.size() == 2 and not str(inserts[0]["sql"]).contains("ON CONFLICT")
	)
	_check(
		"bound as player, stat, dim, amount, name, revision 0, time",
		inserts.size() == 2 and (inserts[0]["params"] as Array).slice(0, 6) == ["p'1", "kills", "", 2.0, "O'Brien", 0]
			and not str(inserts[0]["sql"]).contains("O'Brien")
	)

	driver.clear()
	driver.answers = {"SELECT stat, dim, amount, revision": [{"stat": "kills", "dim": "weapon:rifle", "amount": 5.0, "revision": 2}]}
	var cell: DotResult = await store.merge(&"p2", {"kills": 1, "kills|weapon:rifle": 2}, schema)
	var cell_updates := driver.matching("UPDATE dot_stats_values")
	var cell_inserts := driver.matching("INSERT INTO dot_stats_values")
	_check(
		"a breakdown cell is its own row: updated by dim, the total inserted with dim empty",
		cell.ok and cell_updates.size() == 1 and (cell_updates[0]["params"] as Array)[0] == 7.0
			and (cell_updates[0]["params"] as Array).slice(3) == ["p2", "kills", "weapon:rifle", 2]
			and cell_inserts.size() == 1 and (cell_inserts[0]["params"] as Array).slice(0, 4) == ["p2", "kills", "", 1.0],
		cell
	)
	driver.answers = {"SELECT stat, dim, amount, revision": [
		{"stat": "kills", "dim": "", "amount": 8.0, "revision": 1},
		{"stat": "kills", "dim": "weapon:rifle", "amount": 5.0, "revision": 1},
	]}
	var read_back: DotResult = await store.values_for(&"p2")
	_check(
		"values_for returns the cell beside the total",
		read_back.ok and (read_back.value as DotStatsValues).get_value(&"kills") == 8.0
			and float((read_back.value as DotStatsValues).cells.get("kills|weapon:rifle", 0.0)) == 5.0
	)

	# An existing row: the rule runs HERE, and the value is written guarded by revision.
	driver.clear()
	driver.answers = {"SELECT stat, dim, amount, revision": [
		{"stat": "kills", "dim": "", "amount": 7.0, "revision": 4.0},
		{"stat": "top_speed", "dim": "", "amount": "30.5", "revision": 1},
		{"stat": "best_lap", "dim": "", "amount": 12.5, "revision": 2},
	]}
	await store.merge(&"p1", {"kills": 3, "top_speed": 20.0, "best_lap": 11.0}, schema, "")
	var updates := driver.matching("UPDATE dot_stats_values")
	_check("a best that was not beaten writes nothing; the others write once each", updates.size() == 2)
	_check(
		"a counter's new total is computed by DotStatsDef.merge and bound: 7 + 3, at revision 4",
		updates.size() == 2 and (updates[0]["params"] as Array)[0] == 10.0
			and (updates[0]["params"] as Array).slice(3) == ["p1", "kills", "", 4]
	)
	_check(
		"a lowest keeps the lower: 11 over 12.5",
		updates.size() == 2 and (updates[1]["params"] as Array)[0] == 11.0
	)
	_check(
		"and the guard is in the statement",
		updates.size() == 2 and str(updates[0]["sql"]).contains("WHERE player = ? AND stat = ? AND dim = ? AND revision = ?")
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
		raced.ok and driver.matching("SELECT stat, dim, amount, revision").size() == 3
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
	driver.answers = {"SELECT stat, dim, amount, revision": []}
	driver.fail_inserts = 2
	var refused: DotResult = await store.merge(&"p5", {"kills": 1, "level": 3}, schema)
	_check(
		"an insert that fails with no row behind it is a failure, with both stats unapplied",
		not refused.ok and driver.matching("SELECT stat, dim, amount, revision").size() == 2
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

func _v2_json() -> Dictionary:
	return {
		"version": 2,
		"stats": [
			{"id": "g.kills", "kind": "COUNTER", "type": "INT", "breakdowns": ["weapon", "map"], "publish": true,
			 "column": "default", "category": "combat", "order": 10, "max_rate": 120, "source": "server"},
			{"id": "g.shots", "kind": "COUNTER", "type": "INT", "breakdowns": ["weapon"], "publish": true},
			{"id": "g.longest", "kind": "BEST", "type": "NUMBER", "min": 0, "max": 500, "unit": "m", "format": "distance",
			 "breakdowns": ["weapon"], "better": "higher"},
			{"id": "g.played", "kind": "COUNTER", "type": "DURATION", "breakdowns": ["weapon"]},
			{"id": "g.accuracy", "derived": {"op": "ratio", "num": "g.kills", "den": "g.shots", "scale": 100},
			 "format": "percent", "decimals": 1, "breakdowns": ["weapon"]},
		],
		"rules": [
			{"on": "kill", "stat": "g.kills"},
			{"on": "kill", "stat": "g.longest", "value": "distance"},
			{"on": "shot", "stat": "g.shots", "when": ["hit"], "unless": ["practice"]},
		],
	}


func _v2_refused(patch: Callable) -> bool:
	var data := _v2_json()
	patch.call(data["stats"])
	return not DotStatsSchema.from_dictionary(data).ok


func _test_v2_declarations() -> void:
	_section("v2 declarations")

	var parsed := DotStatsSchema.from_dictionary(_v2_json())
	_check("a v2 schema loads", parsed.ok, parsed)
	if not parsed.ok:
		return
	var schema: DotStatsSchema = parsed.value
	var kills := schema.find(&"g.kills")
	_check("fields are read", kills.value_type == DotStatsDef.ValueType.INT and kills.breakdowns == PackedStringArray(["weapon", "map"]) and kills.max_rate == 120.0 and kills.column == "default" and kills.order == 10)
	var longest := schema.find(&"g.longest")
	_check("bounds are read", longest.has_min and longest.has_max and longest.max_value == 500.0 and longest.format == "distance")
	_check("a derived stat is read", schema.find(&"g.accuracy").derived != null and schema.find(&"g.accuracy").derived.scale == 100.0)
	_check("rules are read", schema.rules.size() == 3 and schema.rules[2].when == PackedStringArray(["hit"]) and schema.rules[1].value_field == "distance")

	var again := DotStatsSchema.from_dictionary(schema.to_dictionary())
	_check("it round trips", again.ok and JSON.stringify(again.value.to_dictionary()) == JSON.stringify(schema.to_dictionary()), again)

	var v1 := DotStatsSchema.from_dictionary({"stats": [{"id": "kills", "kind": "COUNTER", "publish": true}]})
	_check("a v1 declaration still loads with v1 defaults", v1.ok and v1.value.find(&"kills").source == "server" and v1.value.find(&"kills").breakdowns.is_empty() and not v1.value.find(&"kills").has_max)

	var wire := DotStatsReporter.wire_definition(longest)
	_check("define sends type, min and max", wire["type"] == "NUMBER" and wire["min"] == 0.0 and wire["max"] == 500.0 and wire["key"] == "g.longest")
	var wire_kills := DotStatsReporter.wire_definition(kills)
	_check("and the v2 fields", wire_kills["maxRate"] == 120.0 and wire_kills["breakdowns"] == ["weapon", "map"] and wire_kills["column"] == "default" and not wire_kills.has("publish"))
	_check("an unbounded stat sends no bound", not DotStatsReporter.wire_definition(schema.find(&"g.shots")).has("min"))

	_check("three breakdowns are refused", _v2_refused(func(l): l[0]["breakdowns"] = ["weapon", "map", "class"]))
	_check("min above max is refused", _v2_refused(func(l): l[2]["min"] = 900))
	_check("an unknown type is refused", _v2_refused(func(l): l[0]["type"] = "TEXT"))
	_check("an unknown column is refused", _v2_refused(func(l): l[0]["column"] = "loud"))
	_check("a derived stat with a kind is refused", _v2_refused(func(l): l[4]["kind"] = "GAUGE"))
	_check("a derived stat with bounds is refused", _v2_refused(func(l): l[4]["max"] = 100))
	_check("a derived input that is not declared is refused", _v2_refused(func(l): l[4]["derived"]["den"] = "g.nope"))
	_check("a derived breakdown its inputs lack is refused", _v2_refused(func(l): l[4]["breakdowns"] = ["map"]))
	_check("max_rate on a best is refused", _v2_refused(func(l): l[2]["max_rate"] = 5))
	_check("a rule on an undeclared stat is refused", not DotStatsSchema.from_dictionary({"stats": [], "rules": [{"on": "kill", "stat": "x"}]}).ok)
	_check("a newer version is refused", not DotStatsSchema.from_dictionary({"version": 3, "stats": []}).ok)

	var values := DotStatsValues.new()
	var acc: DotStatsDerived = schema.find(&"g.accuracy").derived
	values.record(kills, 3.0, {"weapon": "rifle"})
	_check("a derived stat with no divisor is NAN", is_nan(acc.compute(values)))
	values.record(schema.find(&"g.shots"), 4.0, {"weapon": "rifle"})
	_check("a ratio scales", is_equal_approx(acc.compute(values), 75.0) and is_equal_approx(acc.compute(values, "weapon:rifle"), 75.0))

	_line("")
	_done()


func _test_cells_and_events() -> void:
	_section("cells and events")

	var schema: DotStatsSchema = DotStatsSchema.from_dictionary(_v2_json()).value
	var tracker := DotStatsTracker.new()
	tracker.schema = schema
	tracker.name = "CellTracker"
	add_child(tracker)
	var seen: Array = []
	tracker.event_seen.connect(func(_p, e, _d): seen.append(str(e)))
	var refusals: Array = []
	tracker.refused.connect(func(_p, _s, why): refusals.append(why))
	var p := &"p1"

	tracker.set_context({"map": &"dm_canyon"})
	tracker.record(p, &"g.kills", 1.0, {"weapon": &"rifle"})
	tracker.record(p, &"g.kills", 2.0, {"weapon": &"pistol"})
	var s := tracker.session_values(p)
	_check("a record lands in the total", s.get_value(&"g.kills") == 3.0)
	_check("and in each weapon cell", s.get_cell(&"g.kills", "weapon:rifle") == 1.0 and s.get_cell(&"g.kills", "weapon:pistol") == 2.0)
	_check("and the context fills the missing map axis", s.get_cell(&"g.kills", "map:dm_canyon") == 3.0)
	tracker.record(p, &"g.kills", 1.0, {"class": &"medic", "weapon": &"rifle"})
	_check("an axis the stat lacks is ignored", not s.has_cell(&"g.kills", "class:medic") and s.get_cell(&"g.kills", "weapon:rifle") == 2.0)

	tracker.record(p, &"g.longest", 40.0, {"weapon": &"rifle"})
	tracker.record(p, &"g.longest", 25.0, {"weapon": &"rifle"})
	_check("a best cell keeps the higher by its own kind", s.get_cell(&"g.longest", "weapon:rifle") == 40.0)
	_check("a stat with no weapon given has no weapon cell", not s.has_cell(&"g.shots", "weapon:rifle"))

	tracker.set_context({"map": ""})
	tracker.record(p, &"g.kills")
	_check("clearing the context stops the map cell", s.get_cell(&"g.kills", "map:dm_canyon") == 4.0 and s.get_value(&"g.kills") == 5.0)

	_check("the cells group for the wire", s.to_by()["weapon"]["rifle"]["g.kills"] == 2.0 and s.to_by()["map"]["dm_canyon"]["g.kills"] == 4.0)

	var delta := DotStatsValues.new()
	delta.record(schema.find(&"g.kills"), 5.0, {"weapon": "rifle"})
	s.merge_from(delta, schema)
	_check("merge_from folds cells by kind", s.get_cell(&"g.kills", "weapon:rifle") == 7.0)

	_check("a derived stat cannot be recorded", not tracker.record(p, &"g.accuracy", 1.0).ok and "derived" in refusals)
	_check("a fractional INT is refused", not tracker.record(p, &"g.kills", 0.5).ok and "not_integer" in refusals)
	_check("a reading past max is refused", not tracker.record(p, &"g.longest", 900.0).ok and "above_max" in refusals and s.get_value(&"g.longest") == 40.0)
	_check("a bad axis value drops the cell, not the reading", tracker.record(p, &"g.kills", 1.0, {"weapon": "a b|c"}).ok and not s.cells.has("g.kills|weapon:a b|c"))

	var landed := tracker.event(&"p2", &"kill", {"weapon": &"rifle", "distance": 33.5, "tags": PackedStringArray(["headshot"])})
	var s2 := tracker.session_values(&"p2")
	_check("an event runs its rules", landed == 2 and s2.get_value(&"g.kills") == 1.0 and s2.get_value(&"g.longest") == 33.5)
	_check("with the weapon cell from the data", s2.get_cell(&"g.longest", "weapon:rifle") == 33.5)
	tracker.event(&"p2", &"shot", {"tags": PackedStringArray(["hit"])})
	tracker.event(&"p2", &"shot", {"tags": PackedStringArray(["hit", "practice"])})
	tracker.event(&"p2", &"shot", {"tags": PackedStringArray()})
	_check("when and unless filter by tag", s2.get_value(&"g.shots") == 1.0)
	_check("an event with a missing value field skips that rule", tracker.event(&"p2", &"kill", {}) == 1)
	_check("event_seen is emitted for every event", seen.size() == 5)

	schema.rules.append(DotStatsRule.custom(&"bonus", &"g.kills", func(_pl, d): return float(d["n"]) * 2.0 if d.has("n") else NAN))
	tracker.event(&"p2", &"bonus", {"n": 3})
	tracker.event(&"p2", &"bonus", {})
	_check("a custom rule decides its reading", s2.get_value(&"g.kills") == 8.0)

	tracker.begin(&"p3", "Ada")
	tracker.record(&"p3", &"g.kills", 1.0, {"weapon": &"rifle"})
	_check("ending a player with cells returns them", tracker.end(&"p3").get_cell(&"g.kills", "weapon:rifle") == 1.0)
	tracker.queue_free()

	var logged := DotStatsTracker.new()
	logged.schema = schema
	logged.log_events = true
	logged.max_events = 100
	add_child(logged)
	logged.set_context({"map": &"dm_canyon"})
	logged.begin(&"q1", "Q", {"tmc_user": "u9", "server": "s1"})
	logged.record(&"q1", &"g.kills", 1.0, {"weapon": &"rifle", "mood": &"angry", "bad": "a b"})
	var rows := logged.drain_events()
	_check("an event row has session, player, stat, dims, value and time", rows.size() == 1 and rows[0]["stat"] == "g.kills" and rows[0]["player"] == "q1" and rows[0]["session"] == logged.session_info(&"q1")["session"] and rows[0]["value"] == 1.0 and rows[0]["t"] > 0.0)
	_check("its dimensions are free-form but clean", rows[0]["dims"] == {"map": "dm_canyon", "weapon": "rifle", "mood": "angry"})
	_check("draining empties the log", logged.drain_events().is_empty())
	_check("a session is opaque unless linking is on", not logged.session_info(&"q1").has("tmc_user") and logged.session_info(&"q1")["server"] == "s1")
	logged.link_tmc_user = true
	logged.begin(&"q2", "R", {"tmc_user": "u9"})
	_check("an opted-in session carries the TMC user", logged.session_info(&"q2")["tmc_user"] == "u9")
	var ended: Array = []
	logged.session_ended.connect(func(row): ended.append(row))
	logged.end(&"q2")
	_check("ending a session reports its duration", ended.size() == 1 and ended[0].has("duration") and ended[0]["map"] == "dm_canyon")
	logged.bot_check = func(id): return str(id).begins_with("bot_")
	logged.begin(&"bot_1", "Bot", {"tmc_user": "u1"})
	logged.record(&"bot_1", &"g.kills")
	logged.record(&"q1", &"g.kills")
	var mixed := logged.drain_events()
	_check("a bot's events carry is_bot=true and a human's false", mixed[0]["is_bot"] == true and mixed[1]["is_bot"] == false)
	_check("a bot never carries a linked-user claim", not logged.session_info(&"bot_1").has("tmc_user") and logged.session_info(&"bot_1")["is_bot"] == true and logged.session_info(&"q1")["is_bot"] == false)
	logged.queue_free()
	_line("")
	_done()


func _test_batch_ids() -> void:
	_section("batch ids and source")

	var backbone := FakeBackbone.new()
	var reporter := DotStatsReporter.with_client(backbone, _make_schema())
	reporter.queue(&"p1", "Ada", {"kills": 3})
	backbone.fail = true
	await reporter.flush()
	reporter.queue(&"p1", "Ada", {"kills": 2})
	reporter.queue(&"p2", "Bob", {"deaths": 1})
	await reporter.flush()
	_check("a failed batch is resent under the same id with the same payload", backbone.calls.size() == 2 and backbone.calls[0]["body"]["batch"] == backbone.calls[1]["body"]["batch"] and backbone.calls[0]["body"]["players"] == backbone.calls[1]["body"]["players"])
	backbone.fail = false
	var ok := await reporter.flush_all()
	_check("what was queued meanwhile follows as a new batch", ok.ok and backbone.calls.size() == 4 and backbone.calls[3]["body"]["batch"] != backbone.calls[2]["body"]["batch"] and reporter.queued() == 0)
	_check("a batch id is sent on the first attempt", str(backbone.calls[0]["body"].get("batch", "")) != "")

	var client_def: DotStatsSchema = DotStatsSchema.from_dictionary({"stats": [{"id": "x", "kind": "COUNTER", "source": "client"}, {"id": "y", "kind": "COUNTER"}]}).value
	_check("define sends source in the site's case", DotStatsReporter.wire_definition(client_def.find(&"x"))["source"] == "CLIENT" and DotStatsReporter.wire_definition(client_def.find(&"y"))["source"] == "SERVER")
	_line("")
	_done()


func _test_v2_submit() -> void:
	_section("v2 submit shape, max_rate, breakdown cells in SQL")

	var schema: DotStatsSchema = DotStatsSchema.from_dictionary({"stats": [
		{"id": "kills", "kind": "COUNTER", "publish": true, "breakdowns": ["weapon"], "max_rate": 60},
		{"id": "best", "kind": "BEST", "publish": true},
	]}).value
	var backbone := FakeBackbone.new()
	var tracker := DotStatsTracker.new()
	tracker.schema = schema
	tracker.report_to_backbone = true
	tracker.define_on_start = false
	tracker.link_tmc_user = true
	tracker.report_interval = 0.0
	tracker.reporter.client = backbone
	tracker.reporter.server_id = 12
	var now := [0.0]
	tracker.clock = func() -> float: return now[0]
	add_child(tracker)
	tracker.begin(&"human", "Ada", {"session_id": "s-1", "map": "dm_canyon", "tmc_user": "u1"})
	tracker.begin(&"bot1", "Bot", {"session_id": "s-2", "is_bot": true, "tmc_user": "u2"})
	tracker.record(&"human", &"kills", 3.0, {"weapon": &"rifle"})
	tracker.record(&"bot1", &"kills", 1.0)
	tracker.end(&"bot1")
	await tracker.flush()

	var call: Dictionary = backbone.calls[0]
	var body: Dictionary = call["body"]
	_check("it posts to stats/v2/submit", str(call["path"]) == "stats/v2/submit" and DotStatsReporter.SUBMIT_PATH == "stats/v2/submit")
	_check("with v, batch and the server id", int(body["v"]) == 2 and str(body["batch"]) != "" and int(body["server"]) == 12)
	var by_player := {}
	for p in body["players"]:
		by_player[p["player"]] = p
	_check("a player row carries bot, name, session and stats", by_player.has("human") and by_player["human"]["bot"] == false and by_player["human"]["session"] == DotStatsReporter.wire_session_id("s-1") and float(by_player["human"]["stats"]["kills"]) == 3.0)
	_check("breakdown cells go in by", float(by_player["human"]["by"]["weapon"]["rifle"]["kills"]) == 3.0)
	_check("a linked user is sent for a human", by_player["human"].get("user", "") == "u1")
	_check("a bot is flagged and never carries a user", by_player["bot1"]["bot"] == true and not by_player["bot1"].has("user"))
	var sessions := {}
	for sess in body["sessions"]:
		sessions[str(sess["session"])] = sess
	var s1: Dictionary = sessions.get(DotStatsReporter.wire_session_id("s-1"), {})
	var s2: Dictionary = sessions.get(DotStatsReporter.wire_session_id("s-2"), {})
	_check("sessions list both, the closed one with left", sessions.size() == 2 and s1.get("left", 1) == null and s2.get("left") != null and s1.get("map") == "dm_canyon" and s2.get("bot") == true)
	_check("a session is sent once it is acknowledged", backbone.calls.size() == 1)
	await tracker.flush()
	_check("and not again", backbone.calls.size() == 1)

	# Frozen batch under failure: sessions ride the same payload.
	tracker.end(&"human")
	backbone.fail = true
	await tracker.flush()
	backbone.fail = false
	await tracker.flush()
	_check("a resend keeps the session payload and id", backbone.calls.size() == 3 and backbone.calls[1]["body"] == backbone.calls[2]["body"] and backbone.calls[2]["body"]["sessions"][0]["left"] != null)

	# max_rate: 60 per minute is one a second; the bucket starts full.
	var limited: Array = []
	tracker.refused.connect(func(_p, _s, why): limited.append(why))
	tracker.begin(&"fast", "Fast")
	var landed := 0
	for i in 70:
		if tracker.record(&"fast", &"kills").ok:
			landed += 1
	_check("max_rate refuses a counter growing too fast", landed == 60 and limited.size() == 10 and limited[0] == "over_rate")
	now[0] = 10.0
	_check("and allows it again as time passes", tracker.record(&"fast", &"kills", 10.0).ok and not tracker.record(&"fast", &"kills", 1.0).ok)
	tracker.begin(&"slow", "Slow")
	_check("each player has their own allowance", tracker.record(&"slow", &"kills", 60.0).ok)
	tracker.queue_free()

	# The SQL schema keys a breakdown cell by dim.
	var spec := DotStatsSqlSchema.table_spec()
	var names: Array = []
	for c in spec["columns"]:
		names.append(c["name"])
	_check("the SQL table has a dim column in its key", "dim" in names and "dim" in spec["primary_key"] and DotSqlSchema.validate(spec).ok)
	_check("and the migration upgrades a table without one", DotStatsSqlSchema.migration_steps().size() == 3)
	var loaded := DotStatsValues.from_dictionary({"kills": 4, "kills|weapon:rifle": 3})
	_check("a cell key loads into cells, not the totals", loaded.get_value(&"kills") == 4.0 and float(loaded.cells.get("kills|weapon:rifle", 0.0)) == 3.0 and not loaded.has(&"kills|weapon:rifle"))
	_line("")
	_done()


func _test_client() -> void:
	_section("client")

	var app := FakeApp.new()
	var mine := DotStatsClient.new()
	mine.name = "MyStats"
	mine.schema = _make_schema()
	for d in mine.schema.stats:
		d.source = "client"
	var server_stat := mine.schema.define(&"rank_points")
	server_stat.publish = true
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
	var forged := mine.record(&"rank_points", 99.0)
	_check("a source=server stat is refused by the client", not forged.ok and forged.code() == DotError.CODE_FORBIDDEN and not mine.session_values().has(&"rank_points") and mine.pending() == 2)

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


## The payload the reporter really builds, checked field by field against the site's validator
## (examples/fixtures/dot_submit_v2.schema.json mirrors its zod schema).
func _test_site_contract() -> void:
	_section("site contract: stats/v2/submit")
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://examples/fixtures/dot_submit_v2.schema.json"))
	var schema: DotStatsSchema = DotStatsSchema.from_dictionary({"stats": [
		{"id": "arena.kills", "kind": "COUNTER", "publish": true, "breakdowns": ["weapon", "map"]},
		{"id": "arena.longest_kill", "kind": "BEST", "publish": true},
	]}).value
	var backbone := FakeBackbone.new()
	var tracker := DotStatsTracker.new()
	tracker.schema = schema
	tracker.report_to_backbone = true
	tracker.define_on_start = false
	tracker.link_tmc_user = true
	tracker.report_interval = 0.0
	tracker.reporter.client = backbone
	tracker.reporter.server_id = 12
	add_child(tracker)
	tracker.begin(&"k1", "Ada", {"session_id": "game-session-1", "map": "dm_canyon", "tmc_user": "u1"})
	tracker.begin(&"bot_1", "Bot", {"is_bot": true, "tmc_user": "u2"})
	tracker.record(&"k1", &"arena.kills", 3.0, {"weapon": &"zee.rifle", "map": &"dm_canyon"})
	tracker.record(&"k1", &"arena.longest_kill", 41.2)
	tracker.record(&"bot_1", &"arena.kills", 1.0)
	tracker.end(&"bot_1")
	backbone.fail = true
	await tracker.flush()
	backbone.fail = false
	await tracker.flush()
	var frozen: bool = backbone.calls.size() == 2 and backbone.calls[0]["body"] == backbone.calls[1]["body"]
	_check("a frozen resend is byte-identical", frozen)
	var errors := _validate_submit(backbone.calls[1]["body"], fx)
	_check("the real payload satisfies the site's validator", errors.is_empty(), null)
	if not errors.is_empty():
		_line("  " + "; ".join(errors))
	var body: Dictionary = backbone.calls[1]["body"]
	var human: Dictionary = {}
	var bot: Dictionary = {}
	for p in body["players"]:
		if p["player"] == "k1":
			human = p
		else:
			bot = p
	_check("the human carries user, the bot does not", human.get("user", "") == "u1" and bot["bot"] == true and not bot.has("user"))
	_check("the cells are by axis, value, stat", float(human["by"]["weapon"]["zee.rifle"]["arena.kills"]) == 3.0 and float(human["by"]["map"]["dm_canyon"]["arena.kills"]) == 3.0)
	_check("a non-UUID game session id maps to one stable UUID", human["session"] == DotStatsReporter.wire_session_id("game-session-1") and human["session"] != "game-session-1")

	# The validator itself must refuse what the site refuses, or the check above proves nothing.
	var bad := body.duplicate(true)
	bad["batch"] = "123-456-1"
	_check("the mirror refuses a non-UUID batch", not _validate_submit(bad, fx).is_empty())
	bad = body.duplicate(true)
	bad["players"][0]["stats"]["bad key"] = 1.0
	_check("the mirror refuses a stat key with a space", not _validate_submit(bad, fx).is_empty())
	bad = body.duplicate(true)
	bad["sessions"][0]["joined"] = 1.5
	_check("the mirror refuses a fractional joined", not _validate_submit(bad, fx).is_empty())
	tracker.queue_free()
	_line("")
	_done()


func _test_kills() -> void:
	_section("kills: who killed whom")
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://examples/fixtures/dot_submit_v2.schema.json"))
	var backbone := FakeBackbone.new()
	var tracker := DotStatsTracker.new()
	tracker.schema = DotStatsSchema.from_dictionary({"stats": [{"id": "arena.kills", "kind": "COUNTER", "publish": true}]}).value
	tracker.define_on_start = false
	tracker.report_interval = 0.0
	tracker.reporter.client = backbone
	add_child(tracker)
	tracker.set_context({"map": "dm_canyon", "mode": "ffa"})
	_check("off by default: nothing is queued", not tracker.record_kill(&"a", &"b", "rifle") and tracker.reporter.pending_kills() == 0)
	tracker.report_to_backbone = true
	tracker.begin(&"a", "Ada", {})
	_check("a kill is queued", tracker.record_kill(&"a", &"b", "zee.rifle", {"victim_name": "Bo", "victim_bot": true, "headshot": true}))
	_check("a suicide and a world death are refused", not tracker.record_kill(&"a", &"a") and not tracker.record_kill(&"", &"a"))
	backbone.fail = true
	await tracker.flush()
	backbone.fail = false
	tracker.record_kill(&"b", &"a", "zee.rifle")
	await tracker.flush()
	_check("a failed batch is resent unchanged", backbone.calls.size() == 3 and backbone.calls[0]["body"] == backbone.calls[1]["body"] and backbone.calls[1]["body"]["kills"].size() == 1)
	_check("the later kill rides the next batch, then nothing is pending", backbone.calls[2]["body"]["kills"].size() == 1 and tracker.reporter.pending_kills() == 0)
	var k: Dictionary = backbone.calls[1]["body"]["kills"][0]
	_check("fields: names, bot flags, weapon, map, mode", k["killer_name"] == "Ada" and k["victim_name"] == "Bo" and k["victim_bot"] == true and k["killer_bot"] == false and k["weapon"] == "zee.rifle" and k["map"] == "dm_canyon" and k["mode"] == "ffa" and k["headshot"] == true)
	var errors := _validate_submit(backbone.calls[1]["body"], fx)
	_check("the payload satisfies the site's validator", errors.is_empty(), null)
	for i in 450:
		tracker.reporter.note_kill({"killer": "x", "victim": "y%d" % i, "t": 1})
	var before: int = backbone.calls.size()
	await tracker.flush()
	_check("a batch carries at most the kill limit", backbone.calls.size() - before == 3 and backbone.calls[before]["body"]["kills"].size() == DotStatsReporter.KILL_LIMIT)
	var feed := DotStatsEventFeed.new(tracker)
	feed.key_of = func(id: Variant) -> StringName: return StringName("p%s" % id)
	feed.is_bot = func(id: Variant) -> bool: return int(id) >= 100
	feed.name_of = func(id: Variant) -> String: return "p%s" % id if int(id) >= 100 else ""
	feed.extra = func() -> Dictionary: return {"map": "dm_feed"}
	var pending0: int = tracker.reporter.pending_kills()
	tracker.begin(&"p1", "Ada")
	_check("feed: a kill is queued", feed.report_kill(1, 100, "rifle", {"headshot": true}) and tracker.reporter.pending_kills() == pending0 + 1)
	_check("feed: suicide and world refused", not feed.report_kill(1, 1) and not feed.report_kill(null, 1))
	_check("feed: bot name equal to its key is no name, player name from begin", feed.actor(100)["name"] == "" and feed.actor(1)["name"] == "Ada" and feed.actor(100)["bot"] == true)
	var fed: Array = tracker.reporter._kills
	var last: Dictionary = fed[fed.size() - 1]
	_check("feed: fields", last["killer"] == "p1" and last["victim"] == "p100" and last["victim_bot"] == true and last["killer_bot"] == false and last["killer_name"] == "Ada" and last["victim_name"] == "" and last["map"] == "dm_feed" and last["headshot"] == true)
	_check("hitzones: declared once", DotStatsHitzones.declare(tracker.schema) == 4 and DotStatsHitzones.declare(tracker.schema) == 0)
	_check("hitzones: a hit files hits, damage, kills and side", feed.report_hit(1, 100, "rifle", &"head", 80.0, true, &"left"))
	var hv: DotStatsValues = tracker.session_values(&"p1")
	_check("hitzones: per weapon and zone cells", hv.get_cell(DotStatsHitzones.HITS, "weapon:rifle") == 1.0 and hv.get_cell(DotStatsHitzones.DAMAGE, "zone:head") == 80.0 and hv.get_cell(DotStatsHitzones.KILLS, "zone:head") == 1.0)
	_check("hitzones: side cell", hv.get_cell(DotStatsHitzones.SIDE_HITS, "side:left") == 1.0)
	_check("hitzones: self hits and empty zones are refused", not feed.report_hit(1, 1, "rifle", &"head", 5.0) and not feed.report_hit(1, 100, "rifle", &""))
	_check("penetration: declared once", DotStatsPenetration.declare(tracker.schema) == 3 and DotStatsPenetration.declare(tracker.schema) == 0)
	_check("penetration: a wall kill files hit, damage and kill", feed.report_penetration(1, 100, "rifle", DotStatsPenetration.KIND_WALL, 40.0, true))
	var pv: DotStatsValues = tracker.session_values(&"p1")
	_check("penetration: cells per weapon and kind", pv.get_cell(DotStatsPenetration.HITS, "kind:wall") == 1.0 and pv.get_cell(DotStatsPenetration.DAMAGE, "weapon:rifle") == 40.0 and pv.get_cell(DotStatsPenetration.KILLS, "kind:wall") == 1.0)
	_check("penetration: a ricochet hit files under its own kind", feed.report_penetration(1, 100, "rifle", DotStatsPenetration.KIND_RICOCHET, 12.0) and tracker.session_values(&"p1").get_cell(DotStatsPenetration.HITS, "kind:ricochet") == 1.0)
	_check("penetration: self hits and empty kinds are refused", not feed.report_penetration(1, 1, "rifle", &"body", 5.0) and not feed.report_penetration(1, 100, "rifle", &""))
	tracker.report_to_backbone = false
	tracker.queue_free()
	_done()


func _validate_submit(body: Dictionary, fx: Dictionary) -> Array:
	var e: Array = []
	var key := RegEx.create_from_string(fx["key"])
	var pkey := RegEx.create_from_string(fx["player_key"])
	var uuid := RegEx.create_from_string(fx["uuid"])
	var lim: Dictionary = fx["limits"]
	_allowed(body, fx["top"], "body", e)
	if not (body.get("v") is int or body.get("v") is float) or int(body.get("v", 0)) != 2:
		e.append("v must be 2")
	if body.has("batch") and (not body["batch"] is String or uuid.search(body["batch"]) == null):
		e.append("batch is not a uuid: %s" % body["batch"])
	if body.has("server") and not _is_int(body["server"], 1):
		e.append("server must be a positive integer")
	var sessions: Array = body.get("sessions", [])
	if sessions.size() > int(lim["sessions"]):
		e.append("too many sessions")
	for s in sessions:
		_allowed(s, fx["session"], "session", e)
		if uuid.search(str(s.get("session", ""))) == null:
			e.append("session id is not a uuid")
		if pkey.search(str(s.get("player", ""))) == null:
			e.append("session player key")
		if not _is_int(s.get("joined"), 0):
			e.append("joined must be a non-negative integer")
		if s.get("left") != null and s.has("left") and not _is_int(s["left"], 0):
			e.append("left must be a non-negative integer or null")
		if s.has("bot") and not s["bot"] is bool:
			e.append("session bot must be bool")
		if str(s.get("name", "")).length() > int(fx["session"]["name_max"]) or str(s.get("map", "")).length() > int(fx["session"]["map_max"]):
			e.append("session name/map too long")
	var kills: Array = body.get("kills", [])
	if kills.size() > int(lim["kills"]):
		e.append("too many kills")
	for kl in kills:
		_allowed(kl, fx["kill"], "kill", e)
		if pkey.search(str(kl.get("killer", ""))) == null or pkey.search(str(kl.get("victim", ""))) == null or kl.get("killer") == kl.get("victim"):
			e.append("kill killer/victim key")
		if not _is_int(kl.get("t"), 0):
			e.append("kill t must be a non-negative integer")
		for f in ["killer_bot", "victim_bot", "headshot"]:
			if kl.has(f) and not kl[f] is bool:
				e.append("kill %s must be bool" % f)
		if str(kl.get("killer_name", "")).length() > 64 or str(kl.get("victim_name", "")).length() > 64 or str(kl.get("weapon", "")).length() > 48:
			e.append("kill text too long")
	var players: Array = body.get("players", [])
	if players.size() > int(lim["players"]):
		e.append("too many players")
	var cells := 0
	for p in players:
		_allowed(p, fx["player"], "player", e)
		if pkey.search(str(p.get("player", ""))) == null:
			e.append("player key")
		if p.has("bot") and not p["bot"] is bool:
			e.append("player bot must be bool")
		if p.has("session") and uuid.search(str(p["session"])) == null:
			e.append("player session is not a uuid")
		if str(p.get("name", "")).length() > int(fx["player"]["name_max"]) or str(p.get("user", "")).length() > int(fx["player"]["user_max"]):
			e.append("player name/user too long")
		cells += _check_cells(p.get("stats", {}), key, lim, e)
		for axis in p.get("by", {}):
			if key.search(str(axis)) == null:
				e.append("axis key")
			for value in p["by"][axis]:
				if key.search(str(value)) == null:
					e.append("axis value key")
				cells += _check_cells(p["by"][axis][value], key, lim, e)
	if cells > int(lim["cells"]):
		e.append("too many cells")
	return e


func _check_cells(cells: Variant, key: RegEx, lim: Dictionary, e: Array) -> int:
	if not cells is Dictionary:
		e.append("cells must be an object")
		return 0
	for k in cells:
		if key.search(str(k)) == null:
			e.append("stat key: %s" % k)
		if not (cells[k] is float or cells[k] is int) or is_nan(float(cells[k])) or is_inf(float(cells[k])) or absf(float(cells[k])) > float(lim["value"]):
			e.append("stat value: %s" % k)
	return cells.size()


func _allowed(obj: Variant, spec: Dictionary, what: String, e: Array) -> void:
	if not obj is Dictionary:
		e.append("%s must be an object" % what)
		return
	for r in spec["required"]:
		if not obj.has(r):
			e.append("%s lacks %s" % [what, r])
	for k in obj:
		if not (k in spec["required"] or k in spec["optional"]):
			e.append("%s has unknown key %s" % [what, k])


func _is_int(v: Variant, minimum: int) -> bool:
	return (v is int and v >= minimum) or (v is float and v == floorf(v) and v >= minimum)
