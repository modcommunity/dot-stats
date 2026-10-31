class_name DotStatsPenetration
extends RefCounted
## The stats a game keeps for rounds that passed a wall or a body first, declared once so every game shares ids.
##
## [method declare] adds them to a schema; [method DotStatsEventFeed.report_penetration] fills them. The kind
## (wall, body) is a breakdown axis, so the site can tell a wallbang from a shot through a player.

const HITS := &"penetration_hits"
const KILLS := &"penetration_kills"
const DAMAGE := &"penetration_damage"

const KIND_WALL := &"wall"
const KIND_BODY := &"body"
## A hit by a round that bounced off a wall first (`sv_ricochet`).
const KIND_RICOCHET := &"ricochet"


## Declares the three stats on [param schema] unless already present; returns how many were added.
static func declare(schema: DotStatsSchema) -> int:
	var added := 0
	for spec in [
		[HITS, "Penetrating hits"],
		[KILLS, "Penetrating kills"],
		[DAMAGE, "Penetrating damage"],
	]:
		if schema.has(spec[0]):
			continue
		var def := schema.define(spec[0], DotStatsDef.Kind.COUNTER, spec[1])
		def.breakdowns = PackedStringArray(["weapon", "kind"])
		def.category = "penetration"
		added += 1
	return added
