class_name DotStatsEventFeed
extends RefCounted
## Turns a game's own events into tracker records: the game supplies ids and an event source, never the shape.
##
## Batching stays in [DotStatsReporter]. Other inputs (hitzones, points, rank) add a [code]report_*[/code]
## method that calls [method actor] the same way, so identity rules live in one place.

var tracker: DotStatsTracker
## [code]func(id: Variant) -> StringName[/code]: the stats key of a game-side id. Default is [code]StringName(str(id))[/code].
var key_of: Callable
## [code]func(id: Variant) -> String[/code]: a display name, or "" when unknown.
var name_of: Callable
## [code]func(id: Variant) -> bool[/code]. When unset the tracker's own flag for a begun player applies.
var is_bot: Callable
## [code]func() -> Dictionary[/code] merged under every event (map, mode); the tracker context fills what is missing.
var extra: Callable


func _init(tracker_: DotStatsTracker) -> void:
	tracker = tracker_


## Resolves an id to {key, name, bot}. A name equal to the key is no name: a bot's key is a storage id, and showing it as a name is wrong.
func actor(id: Variant) -> Dictionary:
	var key := key_of.call(id) if key_of.is_valid() else StringName(str(id))
	var label := str(name_of.call(id)) if name_of.is_valid() else ""
	if label == "" or label == String(key):
		label = str(tracker.session_info(key).get("name", "")) if tracker != null else ""
	if label == String(key):
		label = ""
	var bot := bool(is_bot.call(id)) if is_bot.is_valid() else false
	return {"key": key, "name": label, "bot": bot}


## Files one kill for the head-to-head table. Names given in [param meta] as killer_name / victim_name win; refused for world deaths and suicides.
func report_kill(killer: Variant, victim: Variant, weapon: String = "", meta: Dictionary = {}) -> bool:
	if tracker == null or killer == null or victim == null:
		return false
	var k := actor(killer)
	var v := actor(victim)
	if k["key"] == &"" or v["key"] == &"" or k["key"] == v["key"]:
		return false
	var data: Dictionary = extra.call() if extra.is_valid() else {}
	data.merge(meta, true)
	if str(data.get("killer_name", "")) in ["", String(k["key"])]:
		data["killer_name"] = k["name"]
	if str(data.get("victim_name", "")) in ["", String(v["key"])]:
		data["victim_name"] = v["name"]
	data["killer_bot"] = bool(data.get("killer_bot", k["bot"]))
	data["victim_bot"] = bool(data.get("victim_bot", v["bot"]))
	return tracker.record_kill(k["key"], v["key"], weapon, data)


## Files one landed hit by body zone (see [DotStatsHitzones]; the schema must declare them). [param side] is left/middle/right or "". World and self hits are refused.
func report_hit(shooter: Variant, victim: Variant, weapon: String, zone: StringName, amount: float = 0.0, killed: bool = false, side: StringName = &"") -> bool:
	if tracker == null or shooter == null or victim == null or zone == &"":
		return false
	var s := actor(shooter)
	if s["key"] == &"" or s["key"] == actor(victim)["key"]:
		return false
	var wname := weapon if weapon != "" else "unknown"
	# The joint axis is what lets the site show one weapon's zones; separate cells cannot be crossed.
	var dims := {"weapon": wname, "zone": String(zone), "weapon_zone": "%s.%s" % [wname, zone]}
	var ok := tracker.record(s["key"], DotStatsHitzones.HITS, 1.0, dims).ok
	if amount > 0.0:
		ok = tracker.record(s["key"], DotStatsHitzones.DAMAGE, amount, dims).ok and ok
	if killed:
		ok = tracker.record(s["key"], DotStatsHitzones.KILLS, 1.0, dims).ok and ok
	if side != &"":
		dims["side"] = String(side)
		dims["weapon_side"] = "%s.%s" % [wname, side]
		ok = tracker.record(s["key"], DotStatsHitzones.SIDE_HITS, 1.0, dims).ok and ok
	return ok


## Files one hit by a round that passed [param kind] (wall or body) first; see [DotStatsPenetration]. World and self hits are refused.
func report_penetration(shooter: Variant, victim: Variant, weapon: String, kind: StringName, amount: float = 0.0, killed: bool = false) -> bool:
	if tracker == null or shooter == null or victim == null or kind == &"":
		return false
	var s := actor(shooter)
	if s["key"] == &"" or s["key"] == actor(victim)["key"]:
		return false
	var dims := {"weapon": weapon if weapon != "" else "unknown", "kind": String(kind)}
	var ok := tracker.record(s["key"], DotStatsPenetration.HITS, 1.0, dims).ok
	if amount > 0.0:
		ok = tracker.record(s["key"], DotStatsPenetration.DAMAGE, amount, dims).ok and ok
	if killed:
		ok = tracker.record(s["key"], DotStatsPenetration.KILLS, 1.0, dims).ok and ok
	return ok


## Connects a damage signal to [method report_penetration]. [param adapter] maps its arguments to {shooter, victim, weapon, kind, amount, killed}, or {} to skip the event.
func bind_penetrations(source: Signal, adapter: Callable) -> void:
	source.connect(func(a: Variant = null, b: Variant = null, c: Variant = null) -> void:
		var e: Dictionary = adapter.call(a, b, c)
		if e.is_empty():
			return
		var _r := report_penetration(e.get("shooter"), e.get("victim"), str(e.get("weapon", "")), StringName(str(e.get("kind", ""))), float(e.get("amount", 0.0)), bool(e.get("killed", false))))


## Connects a damage signal to [method report_hit]. [param adapter] maps its arguments to {shooter, victim, weapon, zone, amount, killed, side}.
func bind_hits(source: Signal, adapter: Callable) -> void:
	source.connect(func(a: Variant = null, b: Variant = null, c: Variant = null) -> void:
		var e: Dictionary = adapter.call(a, b, c)
		if e.is_empty():
			return
		var _r := report_hit(e.get("shooter"), e.get("victim"), str(e.get("weapon", "")), StringName(str(e.get("zone", ""))), float(e.get("amount", 0.0)), bool(e.get("killed", false)), StringName(str(e.get("side", "")))))


## Connects a kill signal. [param adapter] maps its arguments to {killer, victim, weapon, ...meta}; the signal's arity is the adapter's.
func bind_kills(source: Signal, adapter: Callable) -> void:
	source.connect(func(a: Variant = null, b: Variant = null, c: Variant = null) -> void:
		var e: Dictionary = adapter.call(a, b, c)
		var meta := e.duplicate()
		for k in ["killer", "victim", "weapon"]:
			meta.erase(k)
		report_kill(e.get("killer"), e.get("victim"), str(e.get("weapon", "")), meta))
