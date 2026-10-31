class_name DotStatsPoints
extends RefCounted
## One "points" score fed by configurable sources (kill, headshot, assist, streak, objective, survival); a game supplies events, never amounts.

## Emitted for every award, and by [method mirror] on a client.
signal awarded(player: Variant, source: StringName, amount: int, total: int)

const SOURCE_KILL := &"kill"
const SOURCE_HEADSHOT := &"headshot"
const SOURCE_CRITICAL := &"critical"
const SOURCE_ASSIST := &"assist"
const SOURCE_STREAK := &"streak"
const SOURCE_OBJECTIVE := &"objective"
const SOURCE_SURVIVAL := &"survival"
const SOURCE_MEDAL := &"medal"
## A collectable walked through; the scale is its value.
const SOURCE_PICKUP := &"pickup"

## The wire order of the built-in sources; a game that sends an award by index uses this list.
const ORDER: Array[StringName] = [
	SOURCE_KILL, SOURCE_HEADSHOT, SOURCE_CRITICAL, SOURCE_ASSIST, SOURCE_STREAK,
	SOURCE_OBJECTIVE, SOURCE_SURVIVAL, SOURCE_MEDAL, SOURCE_PICKUP,
]

## The stat id a tracker keeps the lifetime total under.
var stat_id: StringName = &"points"
## Source id to points. A missing or non-positive source awards nothing.
var sources: Dictionary = {
	SOURCE_KILL: 100, SOURCE_HEADSHOT: 25, SOURCE_CRITICAL: 25, SOURCE_ASSIST: 50,
	SOURCE_STREAK: 25, SOURCE_OBJECTIVE: 100, SOURCE_SURVIVAL: 10, SOURCE_PICKUP: 1,
}
## A streak pays [code]streak[/code] points for each kill past the first, up to this many.
var streak_cap: int = 10
## Seconds alive per [code]survival[/code] award.
var survival_interval_sec: float = 30.0
## A player who damaged the victim this recently, and not the killer, gets the assist.
var assist_window_sec: float = 10.0
## Damage a player must have dealt to count as an assist.
var assist_min_damage: float = 20.0
## [code]func(player: Variant, stat: StringName, value: float)[/code], called for every award so a game files it with its tracker.
var record_fn: Callable = Callable()

## Player to points this match; a client's copy is filled by [method mirror].
var totals: Dictionary = {}
var _damage: Dictionary = {}
var _alive_sec: Dictionary = {}


## Adds the lifetime points stat to [param schema]; published, never negative.
static func declare(schema: DotStatsSchema, id: StringName = &"points", display: String = "Points") -> DotStatsDef:
	var def := DotStatsDef.make(id, DotStatsDef.Kind.COUNTER, display)
	def.unit = "pts"
	def.decimals = 0
	def.publish = true
	def.has_min = true
	def.min_value = 0.0
	schema.stats.append(def)
	return def


## Reads source amounts and options from a Dictionary (the shape of [method to_dictionary]); unknown keys are ignored.
func configure(cfg: Dictionary) -> void:
	var table: Variant = cfg.get("sources", {})
	if table is Dictionary:
		for k in table:
			sources[StringName(str(k))] = int(table[k])
	streak_cap = int(cfg.get("streak_cap", streak_cap))
	survival_interval_sec = float(cfg.get("survival_interval_sec", survival_interval_sec))
	assist_window_sec = float(cfg.get("assist_window_sec", assist_window_sec))
	assist_min_damage = float(cfg.get("assist_min_damage", assist_min_damage))


## The configuration as a plain Dictionary, for a JSON file or a describe line.
func to_dictionary() -> Dictionary:
	var table := {}
	for k in sources:
		table[String(k)] = int(sources[k])
	return {
		"sources": table, "streak_cap": streak_cap, "survival_interval_sec": survival_interval_sec,
		"assist_window_sec": assist_window_sec, "assist_min_damage": assist_min_damage,
	}


## Loads [method configure] from a JSON file.
func load_json(path: String) -> DotResult:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return DotResult.fail(DotError.CODE_IO, "No points file at %s." % path)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return DotResult.fail(DotError.CODE_PARSE, "%s is not a JSON object." % path)
	configure(parsed)
	return DotResult.success()


## Awards [param source] (times [param scale]) to [param player]; returns the points landed.
func award(player: Variant, source: StringName, scale: float = 1.0) -> int:
	var amount := roundi(float(sources.get(source, 0)) * scale)
	if amount <= 0:
		return 0
	totals[player] = int(totals.get(player, 0)) + amount
	if record_fn.is_valid():
		record_fn.call(player, stat_id, float(amount))
	awarded.emit(player, source, amount, int(totals[player]))
	return amount


## A client's copy of an award the server made; sets the total, files nothing.
func mirror(player: Variant, source: StringName, amount: int, total: int) -> void:
	totals[player] = total
	awarded.emit(player, source, amount, total)


## Everything one kill is worth: the kill, headshot, critical, a streak step and the assists. Returns the killer's points.
func award_kill(killer: Variant, victim: Variant, now_sec: float, headshot: bool = false,
		critical: bool = false, streak: int = 1) -> int:
	var got := award(killer, SOURCE_KILL)
	if headshot:
		got += award(killer, SOURCE_HEADSHOT)
	if critical:
		got += award(killer, SOURCE_CRITICAL)
	if streak > 1:
		got += award(killer, SOURCE_STREAK, float(mini(streak - 1, streak_cap)))
	for helper in assisters(killer, victim, now_sec):
		var _a := award(helper, SOURCE_ASSIST)
	forget_damage(victim)
	_alive_sec.erase(victim)
	return got


## Notes damage for assists.
func note_damage(attacker: Variant, victim: Variant, amount: float, now_sec: float) -> void:
	if attacker == victim or amount <= 0.0:
		return
	var row: Dictionary = _damage.get(victim, {})
	var cell: Array = row.get(attacker, [0.0, 0.0])
	cell[0] = float(cell[0]) + amount
	cell[1] = now_sec
	row[attacker] = cell
	_damage[victim] = row


## Players other than [param killer] who hurt [param victim] enough and recently enough.
func assisters(killer: Variant, victim: Variant, now_sec: float) -> Array:
	var out: Array = []
	var row: Dictionary = _damage.get(victim, {})
	for who in row:
		var cell: Array = row[who]
		if who != killer and float(cell[0]) >= assist_min_damage and now_sec - float(cell[1]) <= assist_window_sec:
			out.append(who)
	return out


func forget_damage(victim: Variant) -> void:
	_damage.erase(victim)


## Counts [param dt] seconds alive; awards a survival point block per interval.
func survive(player: Variant, dt: float) -> int:
	if survival_interval_sec <= 0.0:
		return 0
	var t := float(_alive_sec.get(player, 0.0)) + dt
	var got := 0
	while t >= survival_interval_sec:
		t -= survival_interval_sec
		got += award(player, SOURCE_SURVIVAL)
	_alive_sec[player] = t
	return got


## A player left, or a new match began.
func forget(player: Variant) -> void:
	totals.erase(player)
	_damage.erase(player)
	_alive_sec.erase(player)
	for victim in _damage:
		(_damage[victim] as Dictionary).erase(player)


func reset() -> void:
	totals.clear()
	_damage.clear()
	_alive_sec.clear()


func describe() -> Dictionary:
	var out := to_dictionary()
	out["totals"] = totals.duplicate()
	return out
