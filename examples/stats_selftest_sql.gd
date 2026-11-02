extends "res://examples/stats_selftest_base.gd"

## The SQL store section of the suite, against a driver that records.


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

	await _sql_first_merges(store, driver, schema)
	await _sql_existing_and_races(store, driver, schema)
	await _sql_rankings(store, driver)

	_line("")
	_done()


## A first merge, and breakdown cells.
func _sql_first_merges(store: DotStatsStoreSql, driver: RacingDriver, schema: DotStatsSchema) -> void:
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


## Merging into rows that exist, and losing races.
func _sql_existing_and_races(store: DotStatsStoreSql, driver: RacingDriver, schema: DotStatsSchema) -> void:
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


## Rankings, ranks and a newer database.
func _sql_rankings(store: DotStatsStoreSql, driver: RacingDriver) -> void:
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
