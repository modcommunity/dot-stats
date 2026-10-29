@tool
class_name DotStatsSqlSchema
extends RefCounted

## The lifetime-values table, its statements and its row mapping, in one place.
##
## Named [code]SqlSchema[/code] because [DotStatsSchema] is already this addon's word for
## the set of stat definitions, and the two would be confused at every call site.
##
## [b]The table is plain data, rendered by dot-sql.[/b] [method table_spec] is a
## [Dictionary] a dot-sql driver turns into DDL for its own dialect. This file names no
## dot-sql class, so dot-stats still parses in a project without it. Placeholders are
## [code]?[/code] in every dialect — dot-sql's contract.
##
## [b]No statement here does arithmetic.[/b] The new value is computed by
## [method DotStatsDef.merge] and written as a value, guarded by `revision` (see
## [DotStatsStoreSql]). The SQL is the same in all three dialects as a result: there is no
## `GREATEST` (which SQLite spells `max`) and no `ON CONFLICT … amount + excluded.amount`
## (which MySQL spells another way) — and no second copy of the rule to disagree with the
## first.

const DEFAULT_TABLE := "dot_stats_values"

## The component the schema version is recorded under in dot-sql's migration table,
## suffixed with the table name. Bumped by adding a step to [method migration_steps], never
## by editing one.
const MIGRATION_COMPONENT := "dot_stats"

## The ranking index's name suffix; the legacy one came from the temporary step-two table.
const INDEX_RANK := "stat_dim_amount_idx"
const INDEX_RANK_LEGACY := "top_dim_idx"

const COLUMNS := ["player", "stat", "dim", "amount", "player_name", "revision", "updated_at"]


## One row per player per stat.
##
## - [b]`revision` is the guard[/b] a read-merge-write needs when two servers share the
##   table: an update says which revision it read, and finds no row if somebody else wrote
##   in between. See [DotStatsStoreSql].
## - [b]The `(stat, amount)` index is the ranking.[/b] [method select_top] is a range scan
##   of it and a rank is a count over it.
## - [b]`player_name` is on every row[/b], denormalised, so a ranking renders without a
##   join to a table this addon does not have. It is the name the player last had.
static func table_spec(table: String = DEFAULT_TABLE) -> Dictionary:
	var spec := _spec_v2(table)
	spec["indexes"] = [{"name": INDEX_RANK, "columns": ["stat", "dim", "amount"]}]
	return spec


## The step-two table with the index name it was first created under (see migration step 3).
static func _spec_v2(table: String) -> Dictionary:
	var spec := _spec_v1(table)
	var columns: Array = spec["columns"]
	columns.insert(2, {"name": "dim", "type": "key", "null": false, "default": ""})
	spec["primary_key"] = ["player", "stat", "dim"]
	spec["indexes"] = [{"name": INDEX_RANK_LEGACY, "columns": ["stat", "dim", "amount"]}]
	return spec


## The table as phase 1a left it, which a database may still hold; migration step one.
static func _spec_v1(table: String) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "player", "type": "key", "null": false},
			{"name": "stat", "type": "key", "null": false},
			{"name": "amount", "type": "real", "null": false, "default": 0},
			{"name": "player_name", "type": "text"},
			{"name": "revision", "type": "bigint", "null": false, "default": 0},
			{"name": "updated_at", "type": "bigint", "null": false, "default": 0},
		],
		"primary_key": ["player", "stat"],
		"indexes": [
			{"name": "top_idx", "columns": ["stat", "amount"]},
		],
	}


## Every schema change, in order, for dot-sql's migrator. Step N brings version N to N+1.
static func migration_steps(table: String = DEFAULT_TABLE) -> Array:
	return [
		[_spec_v1(table)],
		[_upgrade_dim.bind(table)],
		[_rename_rank_index.bind(table)],
	]


## Adds `dim` ('' = the player's total, else `axis:value`) to the key. A key cannot be altered
## portably, so the rows are copied into a new table that replaces the old one.
static func _upgrade_dim(driver: Object, table: String) -> DotResult:
	var fresh := table + "_dim"
	var made: DotResult = await driver.ensure_table(_spec_v2(fresh))
	if not made.ok:
		return made
	for sql in [
		"INSERT INTO %s (player, stat, dim, amount, player_name, revision, updated_at) "
		% fresh + "SELECT player, stat, '', amount, player_name, revision, updated_at FROM %s" % table,
		"DROP TABLE %s" % table,
		"ALTER TABLE %s RENAME TO %s" % [fresh, table],
	]:
		var step: DotResult = await driver.execute(sql)
		if not step.ok:
			return step
	return DotResult.success(true)


## Step three: the ranking index carried the temporary table's name (`<table>_dim_top_dim_idx`).
## Create the new one, then drop the old; both orders are safe to re-run.
static func _rename_rank_index(driver: Object, table: String) -> DotResult:
	var mysql: bool = driver.dialect() == DotSqlDialect.Kind.MYSQL
	var old_name := "%s_%s" % [table + "_dim", INDEX_RANK_LEGACY]
	for sql in rank_index_statements(table, old_name, mysql):
		var step: DotResult = await driver.execute(sql)
		if not step.ok:
			return step
	return DotResult.success(true)


## MySQL has no IF [NOT] EXISTS on indexes; the migrator runs a step once, so plain DDL there.
static func rank_index_statements(table: String, old_name: String, mysql: bool) -> Array:
	var cols := "(stat, dim, amount)"
	var new_name := "%s_%s" % [table, INDEX_RANK]
	if mysql:
		return ["CREATE INDEX %s ON %s %s" % [new_name, table, cols], "DROP INDEX %s ON %s" % [old_name, table]]
	return [
		"CREATE INDEX IF NOT EXISTS %s ON %s %s" % [new_name, table, cols],
		"DROP INDEX IF EXISTS %s" % old_name,
	]


static func select_player(table: String) -> String:
	return "SELECT stat, dim, amount, revision FROM %s WHERE player = ?" % table


## A plain insert, never an upsert: a duplicate key here means another writer created the
## row since it was read, and must fail so the merge re-reads rather than overwriting it.
static func insert_row(table: String) -> String:
	return "INSERT INTO %s (%s) VALUES (?, ?, ?, ?, ?, ?, ?)" % [table, ", ".join(COLUMNS)]


## Writes a merged value only if the row is still at the revision it was read at.
##
## An empty name leaves the stored one alone (`COALESCE(NULLIF(?, ''), player_name)`, the
## same in all three): a merge from a caller that did not know the name must not erase it.
static func update_row(table: String) -> String:
	return (
		"UPDATE %s SET amount = ?, player_name = COALESCE(NULLIF(?, ''), player_name), "
		+ "revision = revision + 1, updated_at = ? "
		+ "WHERE player = ? AND stat = ? AND dim = ? AND revision = ?"
	) % table


## One stat as a ranking, with each row's competition rank as `place`.
##
## [param ascending] — a LOWEST stat — chooses the comparison and the direction, spliced from
## a boolean in code, never from a value. A tie is broken by player id only so a page
## boundary is stable; the rank says they are tied.
static func select_top(table: String, ascending: bool) -> String:
	return (
		"SELECT s.player, s.player_name, s.amount, "
		+ "(SELECT COUNT(*) FROM %s b WHERE b.stat = s.stat AND b.dim = '' AND b.amount %s s.amount) + 1 AS place "
		+ "FROM %s s WHERE s.stat = ? AND s.dim = '' ORDER BY s.amount %s, s.player ASC LIMIT ? OFFSET ?"
	) % [table, "<" if ascending else ">", table, "ASC" if ascending else "DESC"]


## One player's rank on one stat; no row when they hold none.
static func select_rank(table: String, ascending: bool) -> String:
	return (
		"SELECT (SELECT COUNT(*) FROM %s b WHERE b.stat = s.stat AND b.dim = '' AND b.amount %s s.amount) + 1 AS place "
		+ "FROM %s s WHERE s.stat = ? AND s.dim = '' AND s.player = ?"
	) % [table, "<" if ascending else ">", table]


static func delete_player(table: String) -> String:
	return "DELETE FROM %s WHERE player = ?" % table


## A number from a row: a float or an int from JSON, or text from a driver that returns a
## DOUBLE as a string. Null for anything else, so a caller skips it rather than reading 0 —
## a zero that arrived by accident resets a counter.
static func number(value: Variant) -> Variant:
	if value is float or value is int:
		return float(value)
	if value is String and (value as String).is_valid_float():
		return (value as String).to_float()
	return null


## A dialect's name, for logs and [code]describe()[/code]. The integers are dot-sql's.
static func dialect_name(dialect: int) -> String:
	match dialect:
		0: return "sqlite"
		1: return "postgres"
		2: return "mysql"
	return "unknown"
