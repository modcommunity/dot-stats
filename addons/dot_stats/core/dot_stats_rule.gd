@tool
class_name DotStatsRule
extends Resource

## Maps a game event to a reading of one stat, for [method DotStatsTracker.event].

## Event name this rule listens for.
@export var on: StringName = &""
@export var stat: StringName = &""
## Every tag listed must be on the event.
@export var when: PackedStringArray = PackedStringArray()
## No tag listed may be on the event.
@export var unless: PackedStringArray = PackedStringArray()
## A field of the event data to read, or "" to use [member amount].
@export var value_field: String = ""
@export var amount: float = 1.0

## Set by [method custom]: takes (player, data) and returns the reading, or NAN to skip.
var callback: Callable = Callable()


## A rule whose reading is decided by code.
static func custom(event_name: StringName, stat_id: StringName, fn: Callable) -> DotStatsRule:
	var r := DotStatsRule.new()
	r.on = event_name
	r.stat = stat_id
	r.callback = fn
	return r


## The reading this rule gives [param data], or NAN when it does not apply.
func reading(player_id: StringName, data: Dictionary) -> float:
	var tags: Variant = data.get("tags", PackedStringArray())
	for t in when:
		if not _has_tag(tags, t):
			return NAN
	for t in unless:
		if _has_tag(tags, t):
			return NAN
	if callback.is_valid():
		var out: Variant = callback.call(player_id, data)
		return float(out) if (out is float or out is int) else NAN
	if value_field == "":
		return amount
	var raw: Variant = data.get(value_field)
	return float(raw) if (raw is float or raw is int) else NAN


static func _has_tag(tags: Variant, tag: String) -> bool:
	if tags is PackedStringArray:
		return (tags as PackedStringArray).has(tag)
	if tags is Array:
		return (tags as Array).has(tag)
	return false


func to_dictionary() -> Dictionary:
	var out := {"on": String(on), "stat": String(stat)}
	if not when.is_empty():
		out["when"] = Array(when)
	if not unless.is_empty():
		out["unless"] = Array(unless)
	if value_field != "":
		out["value"] = value_field
	elif amount != 1.0:
		out["value"] = amount
	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var r := DotStatsRule.new()
	r.on = StringName(str(data.get("on", "")))
	r.stat = StringName(str(data.get("stat", "")))
	if r.on == &"" or r.stat == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A rule names its event and its stat.")
	for key in ["when", "unless"]:
		var raw: Variant = data.get(key, [])
		if not (raw is Array):
			return DotResult.fail(DotError.CODE_INVALID, "A rule's '%s' is a list of tags." % key, String(r.stat))
		var tags := PackedStringArray()
		for t in (raw as Array):
			tags.append(str(t))
		if key == "when":
			r.when = tags
		else:
			r.unless = tags
	var v: Variant = data.get("value", 1.0)
	if v is String:
		r.value_field = v
	elif v is float or v is int:
		r.amount = float(v)
	else:
		return DotResult.fail(DotError.CODE_INVALID, "A rule's value is a number or a field name.", String(r.stat))
	return DotResult.success(r)
