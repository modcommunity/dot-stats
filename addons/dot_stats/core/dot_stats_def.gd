@tool
class_name DotStatsDef
extends Resource

## One statistic a game keeps per player: what it is called, and how two
## readings of it combine.
##
## [b]The kind is the whole definition.[/b] A name, a unit and a number of
## decimals are presentation; the one thing that has to be agreed by every party
## that ever touches a value — the server that counts it, the reporter that
## batches it, the backbone that stores it — is what happens when a new reading
## meets an old one. Four answers cover everything a game counts, and there are
## four kinds rather than a "merge function" because a rule that lives in code
## is one the backbone cannot apply:
##
## - [constant Kind.COUNTER] adds. Kills, jumps, metres, seconds played.
## - [constant Kind.GAUGE] takes the newest. A level, a rank, a rating.
## - [constant Kind.BEST] keeps the higher. Top speed, longest streak.
## - [constant Kind.LOWEST] keeps the lower. A personal best where lower wins.
##
## The same rule runs in three places on purpose: [method merge] here, the
## reporter's coalescing of a player's readings between flushes, and the
## backbone's merge of a batch into what it holds. Any two of those disagreeing
## is a number that is wrong without anything having failed.
##
## [b]Not a leaderboard.[/b] A board is one number per player, ordered;
## dot-leaderboard has those. A stat is many numbers per player, accumulated, and
## nothing here orders anything. A board over a stat — "most kills" — is the
## site's to derive or the game's to publish through dot-leaderboard.

## How a new reading of the stat combines with the value already held.
enum Kind {
	## Additive. A submission carries the amount to add.
	COUNTER,
	## The newest reading replaces the held one.
	GAUGE,
	## The higher of the two is kept.
	BEST,
	## The lower of the two is kept.
	LOWEST,
}

## Identifier. Never renamed: every value ever filed names its stat by this.
##
## Letters, digits, `_`, `.` and `-`, up to 64 characters, so it survives a JSON
## key, a query string and a column name unchanged.
@export var id: StringName = &""

@export var display_name: String = ""

@export_multiline var description: String = ""

@export var kind: Kind = Kind.COUNTER

## Shown after the value: `m`, `s`, `kills`. Presentation only.
@export var unit: String = ""

@export_range(0, 6, 1) var decimals: int = 0

## Whether the site should list this stat on a player's page.
##
## A stat can be kept and reported without being shown — an input to a rating,
## a figure only a moderator reads.
@export var visible: bool = true

## Send this stat to the backbone at all.
##
## Off by default and deliberately: a server's counters are the server's until
## somebody decides they are public, and one switch per stat is what lets a
## game count something privately while publishing the rest.
@export var publish: bool = false


## How the held value is typed; checked on the tracker and by the site.
enum ValueType { NUMBER, INT, DURATION, BOOL }

const FORMATS := ["", "number", "percent", "duration", "distance", "ratio"]
const COLUMNS := ["default", "optional", "hidden"]
const SOURCES := ["server", "client"]
const BETTER := ["", "higher", "lower"]
## Matches the site (DOT_BREAKDOWNS_MAX); a cell is one "axis:value" dim string, so the count is not a storage limit.
const MAX_BREAKDOWNS := 4

@export var value_type: ValueType = ValueType.NUMBER

## Bounds on the held value; a reading that would leave them is refused.
@export var has_min: bool = false
@export var min_value: float = 0.0
@export var has_max: bool = false
@export var max_value: float = 0.0

## Most a player's held value may grow per minute (COUNTER only); 0 is no limit.
@export var max_rate: float = 0.0

## Axes the stat is also kept per, at most two: `weapon`, `map`, or a game's own.
@export var breakdowns: PackedStringArray = PackedStringArray()

## Display hint, one of [constant FORMATS]; "" follows [member value_type].
@export var format: String = ""
@export var category: String = ""
@export var order: int = 0

## The game's suggestion to the site's owner, one of [constant COLUMNS].
@export var column: String = "optional"

## "higher" or "lower" for sorting; "" follows the kind.
@export var better: String = ""

## "server" (an integration credential writes it) or "client" (the player's own token).
@export var source: String = "server"

## Non-null for a computed stat: never stored, so kind and bounds do not apply.
@export var derived: DotStatsDerived = null


static func make(
	p_id: StringName,
	p_kind: Kind = Kind.COUNTER,
	p_name: String = ""
) -> DotStatsDef:
	var d := DotStatsDef.new()
	d.id = p_id
	d.kind = p_kind
	d.display_name = p_name if p_name != "" else String(p_id).capitalize()
	return d


## The value after [param incoming] meets [param current], by this stat's kind.
##
## [param has_current] is false for a player with nothing held yet, in which
## case every kind takes the incoming value as it is — including a counter,
## whose first submission is its first total.
func merge(current: float, incoming: float, has_current: bool = true) -> float:
	if not has_current:
		return incoming
	match kind:
		Kind.COUNTER:
			return current + incoming
		Kind.GAUGE:
			return incoming
		Kind.BEST:
			return maxf(current, incoming)
		Kind.LOWEST:
			return minf(current, incoming)
	return incoming


func kind_name() -> String:
	return Kind.keys()[kind]


static func kind_from_name(name: String) -> int:
	var idx := Kind.keys().find(name.to_upper())
	return idx if idx >= 0 else -1


## Renders a value the way this stat wants it read.
func format_value(value: float) -> String:
	var text := ("%." + str(decimals) + "f") % value
	return text if unit == "" else "%s %s" % [text, unit]


static func is_valid_id(candidate: String) -> bool:
	if candidate.length() < 1 or candidate.length() > 64:
		return false
	for i in range(candidate.length()):
		var c := candidate.unicode_at(i)
		var ok := (
			(c >= 48 and c <= 57)
			or (c >= 65 and c <= 90)
			or (c >= 97 and c <= 122)
			or c == 95 or c == 46 or c == 45
		)
		if not ok:
			return false
	return true


func validate() -> DotResult:
	if not is_valid_id(String(id)):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A stat id is letters, digits, '_', '.' or '-', up to 64 characters.",
			String(id)
		)
	if display_name.length() > 80:
		return DotResult.fail(
			DotError.CODE_INVALID, "A stat name is at most 80 characters.", String(id)
		)
	if unit.length() > 16:
		return DotResult.fail(
			DotError.CODE_INVALID, "A unit is at most 16 characters.", String(id)
		)
	return _validate_v2()


func _validate_v2() -> DotResult:
	var sid := String(id)
	if not (format in FORMATS) or not (column in COLUMNS) or not (source in SOURCES) or not (better in BETTER):
		return DotResult.fail(DotError.CODE_INVALID, "A format, column, source or better is not one of the allowed names.", sid)
	if breakdowns.size() > MAX_BREAKDOWNS:
		return DotResult.fail(DotError.CODE_INVALID, "A stat has at most %d breakdowns." % MAX_BREAKDOWNS, sid)
	for i in range(breakdowns.size()):
		if not is_valid_id(breakdowns[i]) or breakdowns.find(breakdowns[i]) != i:
			return DotResult.fail(DotError.CODE_INVALID, "A breakdown is an axis name, once.", sid)
	if has_min and has_max and min_value > max_value:
		return DotResult.fail(DotError.CODE_INVALID, "A stat's minimum is above its maximum.", sid)
	if max_rate < 0.0 or not is_finite(max_rate):
		return DotResult.fail(DotError.CODE_INVALID, "max_rate is zero or a positive number.", sid)
	if max_rate > 0.0 and kind != Kind.COUNTER and derived == null:
		return DotResult.fail(DotError.CODE_INVALID, "max_rate applies to counters only.", sid)
	if value_type == ValueType.BOOL and kind == Kind.COUNTER and derived == null:
		return DotResult.fail(DotError.CODE_INVALID, "A yes/no stat cannot be a counter.", sid)
	if derived != null and (has_min or has_max or max_rate > 0.0):
		return DotResult.fail(DotError.CODE_INVALID, "A derived stat has no bounds or rate; it is never stored.", sid)
	return DotResult.success(self)


func value_type_name() -> String:
	return ValueType.keys()[value_type]


## Why [param incoming] does not fit this stat's type and bounds once merged over
## [param current], or "" when it does.
func misfit(current: float, incoming: float, has_current: bool) -> String:
	match value_type:
		ValueType.INT:
			if incoming != floorf(incoming):
				return "not_integer"
		ValueType.BOOL:
			if incoming != 0.0 and incoming != 1.0:
				return "not_bool"
		ValueType.DURATION:
			if incoming < 0.0:
				return "negative_duration"
	var merged := merge(current, incoming, has_current)
	if has_min and merged < min_value:
		return "below_min"
	if has_max and merged > max_value:
		return "above_max"
	return ""


## The shape `POST stats/define` takes, and what [method from_dictionary] reads.
func to_dictionary() -> Dictionary:
	var out := {
		"id": String(id),
		"name": display_name,
		"description": description,
		"unit": unit,
		"decimals": decimals,
		"visible": visible,
		"publish": publish,
		"type": value_type_name(),
		"breakdowns": Array(breakdowns),
		"format": format,
		"category": category,
		"order": order,
		"column": column,
		"better": better,
		"source": source,
	}
	if derived != null:
		out["derived"] = derived.to_dictionary()
	else:
		out["kind"] = kind_name()
		if has_min:
			out["min"] = min_value
		if has_max:
			out["max"] = max_value
		if max_rate > 0.0:
			out["max_rate"] = max_rate
	return out


## The `POST stats/define` entry: the file shape under the backbone's names.
func to_wire() -> Dictionary:
	var out := to_dictionary()
	out.erase("id")
	out.erase("publish")
	out["key"] = String(id)
	out["source"] = source.to_upper()
	if out.has("max_rate"):
		out["maxRate"] = out["max_rate"]
		out.erase("max_rate")
	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var d := DotStatsDef.new()
	d.id = StringName(str(data.get("id", "")))
	d.display_name = str(data.get("name", ""))
	d.description = str(data.get("description", ""))
	d.unit = str(data.get("unit", ""))
	d.decimals = clampi(int(data.get("decimals", 0)), 0, 6)
	d.visible = bool(data.get("visible", true))
	d.publish = bool(data.get("publish", false))

	var parsed := d._read_v2(data)
	if not parsed.ok:
		return parsed

	var k := kind_from_name(str(data.get("kind", "COUNTER")))
	if k < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown stat kind.",
			"%s: '%s'" % [String(d.id), str(data.get("kind"))]
		)
	d.kind = k as Kind

	if d.display_name == "":
		d.display_name = String(d.id).capitalize()

	var valid := d.validate()
	if not valid.ok:
		return valid
	return DotResult.success(d)


func _read_v2(data: Dictionary) -> DotResult:
	var sid := str(data.get("id", ""))
	var t := ValueType.keys().find(str(data.get("type", "NUMBER")).to_upper())
	if t < 0:
		return DotResult.fail(DotError.CODE_INVALID, "Unknown stat type.", "%s: '%s'" % [sid, str(data.get("type"))])
	value_type = t as ValueType
	for key in ["min", "max", "max_rate"]:
		if data.has(key) and not (data[key] is float or data[key] is int):
			return DotResult.fail(DotError.CODE_INVALID, "'%s' must be a number." % key, sid)
		if data.has(key) and not is_finite(float(data[key])):
			return DotResult.fail(DotError.CODE_INVALID, "'%s' must be finite." % key, sid)
	has_min = data.has("min")
	min_value = float(data.get("min", 0.0))
	has_max = data.has("max")
	max_value = float(data.get("max", 0.0))
	max_rate = float(data.get("max_rate", 0.0))
	var axes: Variant = data.get("breakdowns", [])
	if not (axes is Array):
		return DotResult.fail(DotError.CODE_INVALID, "'breakdowns' is a list of axis names.", sid)
	for a in (axes as Array):
		breakdowns.append(str(a))
	format = str(data.get("format", ""))
	category = str(data.get("category", ""))
	order = int(data.get("order", 0))
	column = str(data.get("column", "optional"))
	better = str(data.get("better", ""))
	source = str(data.get("source", "server"))
	if data.has("derived"):
		if data.has("kind"):
			return DotResult.fail(DotError.CODE_INVALID, "A derived stat has no kind.", sid)
		if not (data["derived"] is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "'derived' is an object.", sid)
		var dr := DotStatsDerived.from_dictionary(data["derived"] as Dictionary)
		if not dr.ok:
			return dr.wrap(sid)
		derived = dr.value
	return DotResult.success(self)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"kind": kind_name(),
		"type": value_type_name(),
		"unit": unit,
		"publish": publish,
		"breakdowns": Array(breakdowns),
		"source": source,
		"derived": derived != null,
	}


func _to_string() -> String:
	return "DotStatsDef(%s, %s)" % [String(id), kind_name()]
