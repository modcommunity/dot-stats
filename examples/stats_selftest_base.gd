extends Node

## Harness, fakes and shared sections of the dot-stats suite; stats_selftest.gd extends it.

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


func _make_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()
	schema.define(&"kills").publish = true
	schema.define(&"deaths").publish = true
	schema.define(&"top_speed", DotStatsDef.Kind.BEST).publish = true
	schema.define(&"level", DotStatsDef.Kind.GAUGE).publish = true
	schema.define(&"secret")   # kept, never reported
	return schema


## Every kind, for the stores. `best_lap` is the LOWEST, which ranks the other way.
func _store_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()
	schema.define(&"kills")
	schema.define(&"level", DotStatsDef.Kind.GAUGE)
	schema.define(&"top_speed", DotStatsDef.Kind.BEST)
	schema.define(&"best_lap", DotStatsDef.Kind.LOWEST)
	return schema


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


func _hitzone_schema_valid() -> bool:
	var schema := DotStatsSchema.new()
	DotStatsHitzones.declare(schema)
	return schema.validate().ok


func _hooks_published() -> bool:
	var schema := DotStatsSchema.new()
	DotStatsHitzones.declare(schema)
	DotStatsPenetration.declare(schema)
	for d in schema.stats:
		if not d.publish:
			return false
	return schema.published().size() == schema.size() and schema.size() > 0


func _line(text: String) -> void:
	print(text)


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


# The player's own client

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

	_check("five breakdowns are refused", _v2_refused(func(l): l[0]["breakdowns"] = ["weapon", "map", "class", "mode", "team"]))
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
	_check_event_log(schema)
	_line("")
	_done()


## The event log half of the cells section: rows, sessions, links and bots.
func _check_event_log(schema: DotStatsSchema) -> void:
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

	_check_v2_sql_cells()
	_line("")
	_done()


## The SQL half of the v2 section: a breakdown cell is keyed by dim.
func _check_v2_sql_cells() -> void:
	var spec := DotStatsSqlSchema.table_spec()
	var names: Array = []
	for c in spec["columns"]:
		names.append(c["name"])
	_check("the SQL table has a dim column in its key", "dim" in names and "dim" in spec["primary_key"] and DotSqlSchema.validate(spec).ok)
	_check("and the migration upgrades a table without one", DotStatsSqlSchema.migration_steps().size() == 3)
	var loaded := DotStatsValues.from_dictionary({"kills": 4, "kills|weapon:rifle": 3})
	_check("a cell key loads into cells, not the totals", loaded.get_value(&"kills") == 4.0 and float(loaded.cells.get("kills|weapon:rifle", 0.0)) == 3.0 and not loaded.has(&"kills|weapon:rifle"))


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
	_check("hitzones: joint weapon axes", hv.get_cell(DotStatsHitzones.HITS, "weapon_zone:rifle.head") == 1.0 and hv.get_cell(DotStatsHitzones.SIDE_HITS, "weapon_side:rifle.left") == 1.0)
	_check("hitzones: side cell", hv.get_cell(DotStatsHitzones.SIDE_HITS, "side:left") == 1.0)
	_check("hitzones: self hits and empty zones are refused", not feed.report_hit(1, 1, "rifle", &"head", 5.0) and not feed.report_hit(1, 100, "rifle", &""))
	_check("hitzones: the declared schema validates", DotStatsHitzones.declare(DotStatsSchema.new()) == 4 and _hitzone_schema_valid())
	_check("hook-declared stats pass the reporter publish filter", _hooks_published())
	_check("penetration: declared once", DotStatsPenetration.declare(tracker.schema) == 3 and DotStatsPenetration.declare(tracker.schema) == 0)
	var through := DotStatsFakeDamage.new()
	through.attacker = 1
	through.victim = 100
	through.weapon_id = "rifle"
	through.hit_group = &"knee"
	through.health_lost = 20.0
	through.context = {"penetrated": 1, "wallbang": false, "hit_side": "right"}
	_check("hitzones: a hit through a body files a body-penetration and the knee zone", DotStatsDamage.report(feed, through) == 2 and tracker.session_values(&"p1").get_cell(DotStatsHitzones.HITS, "weapon_zone:rifle.knee") == 1.0 and tracker.session_values(&"p1").get_cell(DotStatsPenetration.HITS, "kind:body") == 1.0)
	_check("penetration: a wall kill files hit, damage and kill", feed.report_penetration(1, 100, "rifle", DotStatsPenetration.KIND_WALL, 40.0, true))
	var pv: DotStatsValues = tracker.session_values(&"p1")
	_check("penetration: cells per weapon and kind", pv.get_cell(DotStatsPenetration.HITS, "kind:wall") == 1.0 and pv.get_cell(DotStatsPenetration.DAMAGE, "weapon:rifle") == 60.0 and pv.get_cell(DotStatsPenetration.KILLS, "kind:wall") == 1.0)
	_check("penetration: a ricochet hit files under its own kind", feed.report_penetration(1, 100, "rifle", DotStatsPenetration.KIND_RICOCHET, 12.0) and tracker.session_values(&"p1").get_cell(DotStatsPenetration.HITS, "kind:ricochet") == 1.0)
	_check("penetration: self hits and empty kinds are refused", not feed.report_penetration(1, 1, "rifle", &"body", 5.0) and not feed.report_penetration(1, 100, "rifle", &""))
	_check("walls: declared once", DotStatsPenetration.declare_walls(tracker.schema) == 2 and DotStatsPenetration.declare_walls(tracker.schema) == 0)
	var fake_shot := DotStatsFakeShot.new()
	fake_shot.attacker = 1
	fake_shot.weapon_id = "rifle"
	fake_shot.penetrations = [{"material": &"wood", "cost": 0.4}, {"material": &"steel", "cost": 2.5}, {"material": &"wood", "cost": 0.2}]
	_check("walls: a shot files one pass per wall", DotStatsDamage.report_shot(feed, fake_shot) == 3)
	var wv: DotStatsValues = tracker.session_values(&"p1")
	_check("walls: cost and passes per material", is_equal_approx(wv.get_cell(DotStatsPenetration.COST, "material:wood"), 0.6) and wv.get_cell(DotStatsPenetration.PASSES, "material:wood") == 2.0 and wv.get_cell(DotStatsPenetration.PASSES, "material:steel") == 1.0)
	_check("walls: joint weapon.material axis", is_equal_approx(wv.get_cell(DotStatsPenetration.COST, "weapon_material:rifle.steel"), 2.5))
	_check("walls: no shot, no material and a world shooter file nothing", DotStatsDamage.report_shot(feed, null) == 0 and not feed.report_wall_pass(1, "rifle", &"", 1.0) and not feed.report_wall_pass(null, "rifle", &"wood", 1.0))
	_check("walls: the declared schema validates", DotStatsPenetration.declare_walls(DotStatsSchema.new()) == 2)
	_check("shots: refused until declared", DotStatsDamage.report_shot_outcome(feed, fake_shot) == 0)
	_check("shots: declared once", DotStatsShots.declare(tracker.schema) == 2 and DotStatsShots.declare(tracker.schema) == 0)
	var missed := DotStatsDamage.report_shot_outcome(feed, fake_shot)
	fake_shot.landed = true
	_check("shots: a miss files a shot, a hit files both", missed == 1 and DotStatsDamage.report_shot_outcome(feed, fake_shot) == 2)
	var sv: DotStatsValues = tracker.session_values(&"p1")
	_check("shots: accuracy counters per weapon", sv.get_cell(DotStatsShots.SHOTS, "weapon:rifle") == 2.0 and sv.get_cell(DotStatsShots.HITS, "weapon:rifle") == 1.0)
	_check("shots: no shot and a world shooter file nothing", DotStatsDamage.report_shot_outcome(feed, null) == 0 and not feed.report_shot_outcome(null, "rifle", true))
	_check("shots: the declared schema validates", DotStatsShots.declare(DotStatsSchema.new()) == 2)
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


## Stand-in for a dot-combat DotDamage (dot-stats names no combat class).
class DotStatsFakeShot:
	extends RefCounted
	var attacker: Variant
	var weapon_id: String
	var penetrations: Array[Dictionary] = []
	var landed := false


	func hit_anyone() -> bool:
		return landed


class DotStatsFakeDamage:
	extends RefCounted
	var attacker: Variant
	var victim: Variant
	var weapon_id: String
	var hit_group: StringName
	var health_lost: float
	var lethal: bool = false
	var context: Dictionary = {}
