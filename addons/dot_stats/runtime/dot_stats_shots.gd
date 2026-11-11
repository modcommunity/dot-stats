class_name DotStatsShots
extends RefCounted
## The two counters accuracy is made of, declared once so every game shares ids: trigger pulls and the pulls that hit someone.
## One shot is one shot, whatever it fired (a shotgun's pellets are one pull). The site derives accuracy from [constant HITS] over [constant SHOTS].
## [method declare] adds them to a schema; [method DotStatsEventFeed.report_shot_outcome] fills them.

const SHOTS := &"shots"
const HITS := &"hits"


## Declares both counters on [param schema] (published, broken down by weapon) unless present; returns how many were added.
static func declare(schema: DotStatsSchema) -> int:
	var added := 0
	for spec in [[SHOTS, "Shots fired"], [HITS, "Shots landed"]]:
		if schema.has(spec[0]):
			continue
		var def := schema.define(spec[0], DotStatsDef.Kind.COUNTER, spec[1])
		def.breakdowns = PackedStringArray(["weapon"])
		def.unit = "shots"
		def.category = "accuracy"
		def.publish = true
		added += 1
	return added
