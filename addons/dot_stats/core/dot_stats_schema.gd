@tool
class_name DotStatsSchema
extends Resource

## Every statistic a game keeps, declared once.
##
## A schema is what a value is checked against before it is counted, what the
## reporter coalesces by, and what is declared to the backbone at boot so that a
## submission names something the site already knows the kind and the unit of.
## A value for a stat nobody declared is refused rather than invented, for the
## reason a leaderboard entry on an undefined board is: a stat born from a
## submission has no name, no merge rule and no unit, so it renders as a number
## nobody can read and merges the wrong way.
##
## Built in code, in the inspector, or from a JSON file the same shape as
## [method to_dictionary] — a game that ships its stats as data can hand the same
## file to the site's operator.

## The most stats one owner may declare. Matched to the backbone's ceiling.
##
## A reporter with a bug that keys a stat by map, or by player, would otherwise
## declare one per map for ever, and every individual request that did it would
## look reasonable.
const MAX_STATS := 200

@export var stats: Array[DotStatsDef] = []

var _by_id: Dictionary = {}
var _indexed_count: int = -1


## Declares a stat and returns it, for building a schema in code.
func define(
	id: StringName,
	kind: DotStatsDef.Kind = DotStatsDef.Kind.COUNTER,
	name: String = ""
) -> DotStatsDef:
	var d := DotStatsDef.make(id, kind, name)
	stats.append(d)
	_indexed_count = -1
	return d


func find(id: StringName) -> DotStatsDef:
	_reindex()
	return _by_id.get(id)


func has(id: StringName) -> bool:
	_reindex()
	return _by_id.has(id)


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for d in stats:
		out.append(String(d.id))
	return out


func published() -> Array[DotStatsDef]:
	var out: Array[DotStatsDef] = []
	for d in stats:
		if d.publish:
			out.append(d)
	return out


func size() -> int:
	return stats.size()


## Refuses a duplicate id, a malformed one, and more stats than the backbone
## will accept.
func validate() -> DotResult:
	if stats.size() > MAX_STATS:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"Too many stats declared.",
			"%d, the most is %d" % [stats.size(), MAX_STATS]
		)

	var seen := {}
	for d in stats:
		if d == null:
			return DotResult.fail(DotError.CODE_INVALID, "A null stat definition.")
		var valid := d.validate()
		if not valid.ok:
			return valid
		if seen.has(d.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A stat id is declared twice.",
				String(d.id)
			)
		seen[d.id] = true

	return DotResult.success(self)


func to_dictionary() -> Dictionary:
	var out: Array = []
	for d in stats:
		out.append(d.to_dictionary())
	return {"stats": out}


static func from_dictionary(data: Dictionary) -> DotResult:
	var schema := DotStatsSchema.new()
	var list: Variant = data.get("stats", [])
	if not (list is Array):
		return DotResult.fail(
			DotError.CODE_PARSE, "A schema is an object with a 'stats' list."
		)

	for entry in (list as Array):
		if not (entry is Dictionary):
			return DotResult.fail(
				DotError.CODE_PARSE, "Each stat must be an object."
			)
		var parsed := DotStatsDef.from_dictionary(entry as Dictionary)
		if not parsed.ok:
			return parsed
		schema.stats.append(parsed.value)

	var valid := schema.validate()
	if not valid.ok:
		return valid
	return DotResult.success(schema)


static func load_json(path: String) -> DotResult:
	var read := DotPaths.read_json(path)
	if not read.ok:
		return read.wrap("Could not read the stats schema.")
	if not (read.value is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "The stats schema must be a JSON object.", path
		)
	var parsed := from_dictionary(read.value as Dictionary)
	if not parsed.ok:
		return parsed.wrap("The stats schema at %s is invalid." % path)
	return parsed


func _reindex() -> void:
	# Rebuilt whenever the array changed size, which is the only way it changes
	# from the inspector or from define(); a def edited in place keeps its id.
	if _indexed_count == stats.size():
		return
	_by_id.clear()
	for d in stats:
		if d != null:
			_by_id[d.id] = d
	_indexed_count = stats.size()


func describe() -> Dictionary:
	return {
		"stats": stats.size(),
		"published": published().size(),
		"ids": ids(),
	}
