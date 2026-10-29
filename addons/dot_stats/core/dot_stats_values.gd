class_name DotStatsValues
extends RefCounted

## A set of stat values for one player, merged by a schema.
##
## [b]Deliberately not dot-leaderboard's [code]DotStatSet[/code].[/b] That class
## is additive everywhere and a caller picks "best" or "lowest" per call; this
## one takes the rule from the definition, so the same [method record] call is
## right for every kind and a counter cannot be handed to a code path that
## treats it as a gauge. The two addons do not import each other, and naming the
## other's class would make this one fail to parse without it.
##
## [b]Everything is a float.[/b] Values cross a network and land in a JSON body,
## and an int/float split is three conversions with two chances to disagree.

## stat id -> float
var values: Dictionary = {}

## "stat|axis:value" -> float, the breakdown cells; each merges by its own stat's kind.
var cells: Dictionary = {}


static func cell_key(id: StringName, cell: String) -> String:
	return String(id) if cell == "" else "%s|%s" % [id, cell]


## Applies a reading by the stat's own rule and returns the new value.
##
## Refuses a non-finite reading rather than storing it: a NaN counter can never
## be added to again and a NaN best can never be beaten, and nothing downstream
## can tell a poisoned value from a real one.
func record(def: DotStatsDef, reading: float, dims: Dictionary = {}) -> DotResult:
	if not is_finite(reading):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A stat reading must be a finite number.",
			String(def.id)
		)
	var has := values.has(def.id)
	var next := def.merge(float(values.get(def.id, 0.0)), reading, has)
	values[def.id] = next
	for axis in dims:
		var key := cell_key(def.id, "%s:%s" % [axis, dims[axis]])
		cells[key] = def.merge(float(cells.get(key, 0.0)), reading, cells.has(key))
	return DotResult.success(next)


## A held value of [param id] in [param cell] ("axis:value"), or the total when "".
func get_cell(id: StringName, cell: String = "", fallback: float = 0.0) -> float:
	var key := cell_key(id, cell)
	return float(cells.get(key, fallback)) if cell != "" else float(values.get(id, fallback))


func has_cell(id: StringName, cell: String = "") -> bool:
	return values.has(id) if cell == "" else cells.has(cell_key(id, cell))


## Cells grouped for the wire: {axis: {value: {stat: float}}}.
func to_by() -> Dictionary:
	var out := {}
	for key in cells:
		var parts := str(key).split("|", true, 1)
		var av := parts[1].split(":", true, 1)
		if not out.has(av[0]):
			out[av[0]] = {}
		if not out[av[0]].has(av[1]):
			out[av[0]][av[1]] = {}
		out[av[0]][av[1]][parts[0]] = float(cells[key])
	return out


func get_value(id: StringName, fallback: float = 0.0) -> float:
	return float(values.get(id, fallback))


func has(id: StringName) -> bool:
	return values.has(id)


func is_empty() -> bool:
	return values.is_empty()


func size() -> int:
	return values.size()


func clear() -> void:
	values.clear()
	cells.clear()


## Folds another set in, stat by stat, by the schema's rules.
##
## What the reporter does with two readings of one player between flushes, and
## what a lifetime total does with a session — the same walk either way. A stat
## the schema does not know is skipped, because there is no rule to merge it by.
func merge_from(other: DotStatsValues, schema: DotStatsSchema) -> void:
	for id in other.values:
		var def := schema.find(id)
		if def == null:
			continue
		var has := values.has(id)
		values[id] = def.merge(
			float(values.get(id, 0.0)), float(other.values[id]), has
		)
	for key in other.cells:
		var def := schema.find(StringName(str(key).split("|")[0]))
		if def == null:
			continue
		cells[key] = def.merge(float(cells.get(key, 0.0)), float(other.cells[key]), cells.has(key))


## A copy, with string keys, for a JSON body.
func to_dictionary() -> Dictionary:
	var out := {}
	for id in values:
		out[String(id)] = float(values[id])
	return out


## Reads a dictionary of readings, dropping anything not numeric.
##
## Dropped rather than coerced: [code]float("banana")[/code] is [code]0.0[/code],
## and a zero that arrived by accident would quietly reset a counter.
static func from_dictionary(data: Dictionary) -> DotStatsValues:
	var v := DotStatsValues.new()
	for key in data:
		var raw: Variant = data[key]
		if raw is float or raw is int:
			var f := float(raw)
			if is_finite(f):
				v.values[StringName(str(key))] = f
	return v


func duplicate_values() -> DotStatsValues:
	var v := DotStatsValues.new()
	v.values = values.duplicate()
	v.cells = cells.duplicate()
	return v


func describe() -> Dictionary:
	return to_dictionary()


func _to_string() -> String:
	return "DotStatsValues(%s)" % JSON.stringify(to_dictionary())
