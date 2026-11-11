class_name DotStatsDamage
extends RefCounted

## Files a landed dot-combat `DotDamage` with a [DotStatsEventFeed]: the hit by body zone, and a round that crossed a wall or body or bounced.
## Duck-typed on the damage (dot-stats names no combat class); what every shooter repeats, called from a `damage_applied` handler for players' shots.

const GENERIC_GROUP := &"generic"
const SIDE_KEY := &"hit_side"


## Reports [param damage] through [param feed]; returns how many events were filed (0 to 2).
static func report(feed: DotStatsEventFeed, damage: Object) -> int:
	if feed == null or damage == null:
		return 0
	return int(report_penetration(feed, damage)) + int(report_hitzone(feed, damage))


## A hit by a round that crossed a wall or a body first, or bounced.
static func report_penetration(feed: DotStatsEventFeed, damage: Object) -> bool:
	var context: Dictionary = damage.get("context")
	var bounced := int(context.get("ricochet", 0)) > 0
	if int(context.get("penetrated", 0)) <= 0 and not bounced:
		return false
	var kind := DotStatsPenetration.KIND_WALL if bool(context.get("wallbang", false)) else DotStatsPenetration.KIND_BODY
	if bounced:
		kind = DotStatsPenetration.KIND_RICOCHET
	return feed.report_penetration(damage.get("attacker"), damage.get("victim"), String(damage.get("weapon_id")), kind,
			float(damage.get("health_lost")), bool(damage.get("lethal")))


## A hit that met a hitbox, by its zone; a trace that met none has no zone.
static func report_hitzone(feed: DotStatsEventFeed, damage: Object) -> bool:
	var group := StringName(damage.get("hit_group"))
	if group == GENERIC_GROUP or group == &"":
		return false
	var context: Dictionary = damage.get("context")
	var side := StringName(str(context.get(SIDE_KEY, "")))
	return feed.report_hit(damage.get("attacker"), damage.get("victim"), String(damage.get("weapon_id")), group,
			float(damage.get("health_lost")), bool(damage.get("lethal")), side)


## Files every wall a resolved dot-combat `DotShot` crossed (its `penetrations`: `material`, `cost`), whether or not a player was behind it. Call from `shot_resolved` for players' shots; returns how many were filed.
static func report_shot(feed: DotStatsEventFeed, shot: Object) -> int:
	if feed == null or shot == null:
		return 0
	var filed := 0
	for pass_info: Dictionary in shot.get("penetrations"):
		if feed.report_wall_pass(shot.get("attacker"), String(shot.get("weapon_id")), StringName(str(pass_info.get("material", ""))), float(pass_info.get("cost", 0.0))):
			filed += 1
	return filed


## Files a resolved dot-combat `DotShot` as one shot, and a hit when it `hit_anyone()` (accuracy: [DotStatsShots]). Call from `shot_resolved` for players' shots; returns how many counters were filed (0 to 2).
static func report_shot_outcome(feed: DotStatsEventFeed, shot: Object) -> int:
	if feed == null or shot == null:
		return 0
	var hit: bool = shot.has_method("hit_anyone") and bool(shot.call("hit_anyone"))
	if not feed.report_shot_outcome(shot.get("attacker"), String(shot.get("weapon_id")), hit):
		return 0
	return 2 if hit else 1
