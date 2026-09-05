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
	return DotResult.success(self)


## The shape `POST stats/define` takes, and what [method from_dictionary] reads.
func to_dictionary() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"description": description,
		"kind": kind_name(),
		"unit": unit,
		"decimals": decimals,
		"visible": visible,
		"publish": publish,
	}


static func from_dictionary(data: Dictionary) -> DotResult:
	var d := DotStatsDef.new()
	d.id = StringName(str(data.get("id", "")))
	d.display_name = str(data.get("name", ""))
	d.description = str(data.get("description", ""))
	d.unit = str(data.get("unit", ""))
	d.decimals = clampi(int(data.get("decimals", 0)), 0, 6)
	d.visible = bool(data.get("visible", true))
	d.publish = bool(data.get("publish", false))

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


func describe() -> Dictionary:
	return {
		"id": String(id),
		"kind": kind_name(),
		"unit": unit,
		"publish": publish,
	}


func _to_string() -> String:
	return "DotStatsDef(%s, %s)" % [String(id), kind_name()]
