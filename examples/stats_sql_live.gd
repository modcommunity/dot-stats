extends Node

## The SQL store against a real database, through dot-sql's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them, ranks the way the kind says, and that two writers folding into one row at once add
## up — in all three dialects. Run by dot-sql's runner, which starts a gateway per dialect
## and sets DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE:
##
## [codeblock]
## ../dot-sql/tools/test_live.sh . res://examples/stats_sql_live.tscn
## [/codeblock]

const CHECKS := 13

const TABLE := "dot_stats_live_values"

## Merges fired at one player at once, one kill each, under DotHttp's pool of 16.
const PILE := 12

## Merges each of two "servers" makes one after another, while the other does the same.
const PER_SERVER := 10

var _passed := 0
var _failed := 0
var _finished := 0
var _landed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var made := DotSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("DOT_SQL_URL"),
		"dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("DOT_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see dot-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: DotSqlDriverGateway = made.value
	print("dot-stats live: %s" % DotSqlDialect.name_of(dialect))

	# A clean table every run.
	await driver.open()
	await _drop(driver)

	var schema := DotStatsSchema.new()
	schema.define(&"kills")
	schema.define(&"level", DotStatsDef.Kind.GAUGE)
	schema.define(&"top_speed", DotStatsDef.Kind.BEST)
	schema.define(&"best_lap", DotStatsDef.Kind.LOWEST)

	var store := _store(driver, schema)
	var opened: DotResult = await store.open()
	_check("the store creates its table", opened.ok, opened)

	var who := &"p'1"
	var first: DotResult = await store.merge(who, {"kills": 3, "level": 2, "top_speed": 30.25, "best_lap": 61.123}, schema, "O'Brien 🙃")
	_check(
		"first readings stand as they are, a LOWEST included",
		first.ok and _v(first).get_value(&"kills") == 3.0 and _v(first).get_value(&"best_lap") == 61.123,
		first
	)

	var second: DotResult = await store.merge(who, {"kills": 4, "level": 1, "top_speed": 20.0, "best_lap": 70.0}, schema)
	_check(
		"each kind folds by its rule: 3+4 kills, the level replaced, the best and the lowest kept",
		second.ok and _v(second).get_value(&"kills") == 7.0 and _v(second).get_value(&"level") == 1.0
			and _v(second).get_value(&"top_speed") == 30.25 and _v(second).get_value(&"best_lap") == 61.123,
		second
	)

	await store.merge(&"p2", {"kills": 7, "best_lap": 59.5}, schema, "Bo")
	await store.merge(&"p3", {"kills": 1, "best_lap": 61.123}, schema, "Cy")

	var kills: DotResult = await store.top(&"kills")
	_check(
		"a counter ranks highest first, a tie sharing its rank (1, 1, 3)",
		_shape(kills) == "p'1=1 p2=1 p3=3", kills, _shape(kills)
	)
	_check(
		"and a name kept with a quote and an emoji in it, from the first merge, not erased by the second",
		kills.ok and (kills.value as Array)[0]["name"] == "O'Brien 🙃"
	)

	var laps: DotResult = await store.top(&"best_lap")
	_check("a LOWEST ranks lowest first (1, 2, 2)", _shape(laps) == "p2=1 p'1=2 p3=2", laps, _shape(laps))

	var page: DotResult = await store.top(&"best_lap", 1, 1)
	_check("a limit and an offset page through it", _shape(page) == "p'1=2", page, _shape(page))

	var rank: DotResult = await store.rank_of(&"best_lap", &"p3")
	var none: DotResult = await store.rank_of(&"best_lap", &"nobody")
	_check("a rank, and 0 for a player who holds none", rank.ok and rank.value == 2 and none.ok and none.value == 0, rank)

	# Two servers folding into one row at once. Without the revision guard the read-fold-write
	# of one overwrites the other's and the total comes up short. First a pile-up nothing real
	# produces — twelve merges of one player in flight at once — where some give up after
	# max_attempts; what matters is that every one that SAID it landed did, and no more.
	var server_a := _store(driver, schema)
	var server_b := _store(driver, schema)
	await server_a.open()
	await server_b.open()
	for i in PILE / 2:
		_race(server_a, schema, &"pile")
		_race(server_b, schema, &"pile")
	await _wait_for(PILE)
	var piled: DotResult = await store.values_for(&"pile")
	_check(
		"a pile-up of %d merges: the total is exactly the %d that reported landing" % [PILE, _landed],
		_finished == PILE and piled.ok and _v(piled).get_value(&"kills") == float(_landed),
		piled, "%d finished, %d landed, total %s" % [_finished, _landed, str(_v(piled).get_value(&"kills")) if piled.ok else "?"]
	)

	# Then the real shape: two servers, each writing one player's checkpoints in turn (a
	# tracker writes one at a time), at the same moment as each other.
	_finished = 0
	_landed = 0
	var lost_before := server_a.conflicts + server_b.conflicts
	_server(server_a, schema)
	_server(server_b, schema)
	await _wait_for(PER_SERVER * 2)
	var raced: DotResult = await store.values_for(&"racer")
	_check(
		"two servers writing one player at once add up: %d (%d lost races, re-read and retried)" % [
			PER_SERVER * 2, server_a.conflicts + server_b.conflicts - lost_before
		],
		_landed == PER_SERVER * 2 and raced.ok and _v(raced).get_value(&"kills") == float(PER_SERVER * 2),
		raced, "%d landed, total %s" % [_landed, str(_v(raced).get_value(&"kills")) if raced.ok else "?"]
	)

	var removed: DotResult = await store.remove_player(&"p3")
	var gone: DotResult = await store.values_for(&"p3")
	_check("a player can be forgotten", removed.ok and removed.value == true and gone.ok and _v(gone).is_empty(), removed)

	# A tracker with no backbone keeps lifetime totals across two sessions.
	var tracker := _tracker(store, schema)
	tracker.begin(&"p9", "Nine")
	tracker.record(&"p9", &"kills", 2.0)
	tracker.end(&"p9")
	await tracker.flush()
	tracker.begin(&"p9", "Nine")
	tracker.record(&"p9", &"kills", 5.0)
	await tracker.flush()
	var lifetime: DotResult = await store.values_for(&"p9")
	_check("a tracker with no backbone keeps a lifetime total across sessions: 2 + 5", lifetime.ok and _v(lifetime).get_value(&"kills") == 7.0, lifetime)
	tracker.queue_free()

	var reopen: DotResult = await _store(driver, schema).open()
	_check("opening an existing table again is harmless", reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await _drop(driver)
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _race(store: DotStatsStoreSql, schema: DotStatsSchema, player: StringName) -> void:
	var res: DotResult = await store.merge(player, {"kills": 1}, schema, "Racer")
	if res.ok:
		_landed += 1
	_finished += 1


func _server(store: DotStatsStoreSql, schema: DotStatsSchema) -> void:
	for i in PER_SERVER:
		await _race(store, schema, &"racer")


func _wait_for(count: int) -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while _finished < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _store(driver, schema: DotStatsSchema) -> DotStatsStoreSql:
	var store := DotStatsStoreSql.new(driver)
	store.table = TABLE
	store.schema = schema
	return store


func _tracker(store: DotStatsStore, schema: DotStatsSchema) -> DotStatsTracker:
	var tracker := DotStatsTracker.new()
	tracker.schema = schema
	tracker.report_to_backbone = false
	tracker.report_interval = 0.0
	tracker.store = store
	add_child(tracker)
	return tracker


func _v(res: DotResult) -> DotStatsValues:
	return res.value if res.ok and res.value is DotStatsValues else DotStatsValues.new()


func _shape(res: DotResult) -> String:
	if not res.ok:
		return "?"
	var parts := PackedStringArray()
	for row in (res.value as Array):
		parts.append("%s=%d" % [row["player"], row["rank"]])
	return " ".join(parts)


func _drop(driver) -> void:
	await driver.execute("DROP TABLE IF EXISTS %s" % TABLE)
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_stats:%s" % TABLE])


func _check(what: String, passed: bool, res: DotResult = null, detail: String = "") -> void:
	if passed:
		_passed += 1
		print("  %-60s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	elif detail != "":
		why = " — %s" % detail
	print("  %-60s FAILED%s" % [what, why])
