class_name DotStatsStoreSql
extends DotStatsStore

## Lifetime values in a real table, in whichever SQL a dot-sql driver speaks.
##
## [codeblock]
## var store := DotStatsStoreSql.new(DotSqlDriverSqlite.new("user://stats.db"))
## var opened := await store.open()      # creates or migrates the table
## tracker.store = store                 # before add_child, so its timer runs
## [/codeblock]
##
## [b]The driver is duck-typed[/b] — held untyped and asked for `query`, `execute`,
## `dialect` and `migrate` — so dot-stats does not depend on dot-sql and parses in a
## project without it. The table is [DotStatsSqlSchema]'s.
##
## [b]A merge is read, fold, write — guarded.[/b] The fold is [method DotStatsDef.merge],
## the addon's one rule (see [DotStatsStore] for why it is not re-spelled as SQL). A read
## and a write are two statements, and a community's servers sharing one database will
## sooner or later fold into one row between them; the second write would then erase the
## first. So every row carries a `revision`, an update names the revision it read, and an
## update that finds no row lost the race: the merge re-reads and folds again, up to
## [member max_attempts] times. A first value is a plain INSERT, never an upsert, so a row
## another server created in between is a duplicate key — re-read, not overwritten.
##
## [b]Stat by stat, so a failure part-way says what did not land[/b], in
## [code]error.context["unapplied"][/code]. The tracker keeps only that for the next try;
## retrying the whole delta would add a counter twice.

const CHANNEL := "stats"

## Where statements go: a dot-sql driver, or anything shaped like one.
var driver = null

## Table name, in case an operator already owns `dot_stats_values` or runs two games in one
## database.
var table: String = DotStatsSqlSchema.DEFAULT_TABLE

## Create or migrate the table on [method open]. Off for a deployment whose schema is
## managed elsewhere and which would rather this touched nothing.
var create_schema: bool = true

## How many times a merge re-reads after losing a race before it gives up. Losing five in a
## row means something is writing the row continuously, and that is worth a failure.
var max_attempts: int = 5

## Diagnostics.
var merges: int = 0
var conflicts: int = 0
var reads: int = 0


func _init(p_driver = null) -> void:
	driver = p_driver


func store_name() -> String:
	return "sql/%s" % (driver.driver_name() if driver != null else "none")


func is_writable() -> bool:
	return driver != null and driver.is_open()


## Opens the driver and, unless told not to, creates or migrates the table.
func open() -> DotResult:
	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "No SQL driver.")

	var available: DotResult = driver.is_available()
	if not available.ok:
		return available

	var opened: DotResult = await driver.open()
	if not opened.ok:
		return opened

	if not create_schema:
		return DotResult.success(true)

	# Versioned: a database from a NEWER build is refused rather than read with columns
	# that have changed meaning underneath it.
	var migrated: DotResult = await driver.migrate(
		"%s:%s" % [DotStatsSqlSchema.MIGRATION_COMPONENT, table],
		DotStatsSqlSchema.migration_steps(table)
	)

	if not migrated.ok:
		return migrated.wrap("Could not prepare the stats table.")

	DotLog.info(CHANNEL, "stats table ready", {
		"dialect": DotStatsSqlSchema.dialect_name(int(driver.dialect())),
		"table": table,
	})

	return DotResult.success(true)


func close() -> void:
	if driver != null:
		driver.close()


func _merge(
	player_id: StringName, incoming: DotStatsValues, p_schema: DotStatsSchema, player_name: String
) -> DotResult:
	var pending: Dictionary = incoming.values.duplicate()

	if not is_writable():
		return _unapplied(DotResult.fail(DotError.CODE_STATE, "The database is not open."), pending)

	var player := String(player_id)
	# An insert that failed, by stat. Kept until the re-read says whether it was a race (the
	# row is there now) or a real failure (it is not).
	var insert_failed: Dictionary = {}
	var attempt := 0

	while not pending.is_empty():
		if attempt >= max_attempts:
			return _unapplied(DotResult.fail(
				DotError.CODE_CONFLICT,
				"A player's stats kept changing underneath the merge.",
				"%s, %d attempts" % [player.substr(0, 16), attempt]
			), pending)
		attempt += 1

		var read: DotResult = await driver.query(DotStatsSqlSchema.select_player(table), [player])
		if not read.ok:
			return _unapplied(read.wrap("Could not read a player's stats."), pending)

		var held := {}
		for row in (read.value as Array):
			if row is Dictionary:
				var amount: Variant = DotStatsSqlSchema.number(row.get("amount"))
				if amount != null:
					held[str(row.get("stat", ""))] = {
						"amount": amount, "revision": int(DotStatsSqlSchema.number(row.get("revision", 0)))
					}

		var now := int(Time.get_unix_time_from_system())

		for stat in pending.keys():
			var def := p_schema.find(stat)
			var reading := float(pending[stat])
			var key := String(stat)

			if held.has(key):
				insert_failed.erase(stat)
				var current: float = held[key]["amount"]
				var next := def.merge(current, reading, true)
				if next == current:
					# A best not beaten, a gauge re-read at the same value: nothing to write.
					pending.erase(stat)
					continue
				var updated: DotResult = await driver.execute(
					DotStatsSqlSchema.update_row(table),
					[next, player_name, now, player, key, held[key]["revision"]]
				)
				if not updated.ok:
					return _unapplied(updated.wrap("Could not write a player's stat."), pending)
				if (updated.value is int or updated.value is float) and int(updated.value) == 0:
					# Lost the race: the row moved since it was read. Fold again.
					conflicts += 1
					continue
				pending.erase(stat)
				continue

			if insert_failed.has(stat):
				# Failed to insert, and the row is still not there: not a race.
				return _unapplied((insert_failed[stat] as DotResult).wrap("Could not write a player's stat."), pending)

			# A first reading stands as it is, whatever the kind — the same call the rule
			# makes everywhere else, rather than a special case here.
			var inserted: DotResult = await driver.execute(
				DotStatsSqlSchema.insert_row(table),
				[player, key, def.merge(0.0, reading, false), player_name, 0, now]
			)
			if inserted.ok:
				pending.erase(stat)
			else:
				# Most likely another writer created the row since the read; the re-read
				# decides.
				conflicts += 1
				insert_failed[stat] = inserted

	merges += 1
	return await values_for(player_id)


func values_for(player_id: StringName) -> DotResult:
	if not is_writable():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var read: DotResult = await driver.query(DotStatsSqlSchema.select_player(table), [String(player_id)])
	if not read.ok:
		return read.wrap("Could not read a player's stats.")

	reads += 1
	var out := DotStatsValues.new()
	for row in (read.value as Array):
		if row is Dictionary:
			var amount: Variant = DotStatsSqlSchema.number(row.get("amount"))
			if amount != null:
				out.values[StringName(str(row.get("stat", "")))] = amount
	return DotResult.success(out)


func top(stat_key: StringName, limit: int = 10, offset: int = 0) -> DotResult:
	var ordering := _ordering(stat_key)
	if not ordering.ok:
		return ordering
	if not is_writable():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var read: DotResult = await driver.query(
		DotStatsSqlSchema.select_top(table, bool(ordering.value)),
		[String(stat_key), maxi(limit, 0), maxi(offset, 0)]
	)
	if not read.ok:
		return read.wrap("Could not read a stat's ranking.")

	reads += 1
	var out: Array = []
	for row in (read.value as Array):
		if not (row is Dictionary):
			continue
		var amount: Variant = DotStatsSqlSchema.number(row.get("amount"))
		if amount == null:
			continue
		var name_value: Variant = row.get("player_name")
		out.append({
			"player": str(row.get("player", "")),
			"name": "" if name_value == null else str(name_value),
			"value": amount,
			"rank": int(DotStatsSqlSchema.number(row.get("place", 0))),
		})
	return DotResult.success(out)


func rank_of(stat_key: StringName, player_id: StringName) -> DotResult:
	var ordering := _ordering(stat_key)
	if not ordering.ok:
		return ordering
	if not is_writable():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var read: DotResult = await driver.query_value(
		DotStatsSqlSchema.select_rank(table, bool(ordering.value)),
		[String(stat_key), String(player_id)], 0
	)
	if not read.ok:
		return read.wrap("Could not read a player's rank.")

	reads += 1
	var place: Variant = DotStatsSqlSchema.number(read.value)
	return DotResult.success(int(place) if place != null else 0)


func remove_player(player_id: StringName) -> DotResult:
	if not is_writable():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var gone: DotResult = await driver.execute(DotStatsSqlSchema.delete_player(table), [String(player_id)])
	if not gone.ok:
		return gone.wrap("Could not remove a player's stats.")

	return DotResult.success(int(gone.value) > 0 if gone.value is int or gone.value is float else true)


## Attaches what did not land to a failure, as readings a caller can re-queue.
static func _unapplied(res: DotResult, pending: Dictionary) -> DotResult:
	var readings := {}
	for stat in pending:
		readings[String(stat)] = float(pending[stat])
	if res.error != null:
		res.error.context["unapplied"] = readings
	return res


func describe() -> Dictionary:
	var out := super.describe()
	out["store"] = store_name()
	out["writable"] = is_writable()
	out["table"] = table
	out["dialect"] = DotStatsSqlSchema.dialect_name(int(driver.dialect()) if driver != null else -1)
	out["merges"] = merges
	out["conflicts"] = conflicts
	out["reads"] = reads
	return out
