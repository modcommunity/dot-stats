class_name DotStatsStoreMemory
extends DotStatsStore

## Lifetime values in a dictionary, lost on exit. For tests, a scratch server, and as the
## reference the SQL store is checked against.

## player id -> {"name": String, "values": DotStatsValues}
var _rows: Dictionary = {}


func _merge(
	player_id: StringName, incoming: DotStatsValues, p_schema: DotStatsSchema, player_name: String
) -> DotResult:
	if not _rows.has(player_id):
		_rows[player_id] = {"name": player_name, "values": DotStatsValues.new()}

	var row: Dictionary = _rows[player_id]
	if player_name != "":
		row["name"] = player_name

	# The rule, from the one place it is written.
	(row["values"] as DotStatsValues).merge_from(incoming, p_schema)

	# A copy: two callers holding the store's own set are two writers to it.
	return DotResult.success((row["values"] as DotStatsValues).duplicate_values())


func values_for(player_id: StringName) -> DotResult:
	var row: Variant = _rows.get(player_id)
	if not (row is Dictionary):
		return DotResult.success(DotStatsValues.new())
	return DotResult.success(((row as Dictionary)["values"] as DotStatsValues).duplicate_values())


func top(stat_key: StringName, limit: int = 10, offset: int = 0) -> DotResult:
	var ordering := _ordering(stat_key)
	if not ordering.ok:
		return ordering
	var ascending: bool = ordering.value

	var held: Array = []
	for id in _rows:
		var values: DotStatsValues = (_rows[id] as Dictionary)["values"]
		if values.has(stat_key):
			held.append({"player": String(id), "name": str((_rows[id] as Dictionary)["name"]), "value": values.get_value(stat_key)})

	# Ties broken by player id only so a page boundary is stable between two reads, the same
	# as the SQL store's ORDER BY; the rank below is what says they are tied.
	held.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["value"] == b["value"]:
			return a["player"] < b["player"]
		return a["value"] < b["value"] if ascending else a["value"] > b["value"]
	)

	for i in range(held.size()):
		if i > 0 and held[i]["value"] == held[i - 1]["value"]:
			held[i]["rank"] = held[i - 1]["rank"]
		else:
			held[i]["rank"] = i + 1

	var start := maxi(offset, 0)
	return DotResult.success(held.slice(start, start + maxi(limit, 0)))


func rank_of(stat_key: StringName, player_id: StringName) -> DotResult:
	var ordering := _ordering(stat_key)
	if not ordering.ok:
		return ordering
	var ascending: bool = ordering.value

	var row: Variant = _rows.get(player_id)
	if not (row is Dictionary) or not ((row as Dictionary)["values"] as DotStatsValues).has(stat_key):
		return DotResult.success(0)

	var mine := ((row as Dictionary)["values"] as DotStatsValues).get_value(stat_key)
	var ahead := 0
	for id in _rows:
		var values: DotStatsValues = (_rows[id] as Dictionary)["values"]
		if not values.has(stat_key):
			continue
		var theirs := values.get_value(stat_key)
		if (theirs < mine) if ascending else (theirs > mine):
			ahead += 1

	return DotResult.success(ahead + 1)


func remove_player(player_id: StringName) -> DotResult:
	return DotResult.success(_rows.erase(player_id))


func size() -> int:
	return _rows.size()


func clear() -> void:
	_rows.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["players"] = _rows.size()
	return out
