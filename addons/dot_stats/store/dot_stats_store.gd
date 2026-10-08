class_name DotStatsStore
extends RefCounted

## Where a player's LIFETIME values live, on the server's side. Subclass point.
##
## [b]What this is for.[/b] The tracker counts a session and sends deltas to the backbone,
## which keeps the totals. A server with no backbone — a LAN, a community that has not
## linked an integration, a game still in development — had nowhere to keep a total at all:
## every number a player earned ended with their session. A store is that somewhere, fed by
## the same deltas at the same moment the reporter is, so a server with both keeps both and
## the two cannot drift apart by when they were told.
##
## [b]The merge rule is not written here.[/b] Every implementation folds a delta in with
## [method DotStatsDef.merge] — the addon's one rule, which the reporter and the backbone
## also follow. A store that spelled it again in SQL (`amount + ?`, `GREATEST`, `LEAST`) would
## be a fifth copy of the rule in a fourth language, and the CLAUDE.md is explicit about what
## two copies disagreeing costs: a number that is wrong without anything having failed.
##
## [b]Everything returns a [DotResult] and every method may be a coroutine[/b]; always
## [code]await[/code]. The interesting implementations are remote.
##
## [b]Ordering comes from the kind.[/b] [method top] and [method rank_of] read the stat's
## definition in [member schema]: a [constant DotStatsDef.Kind.LOWEST] stat ranks ascending,
## every other kind descending. A tie shares a rank (1, 2, 2, 4).

## The definitions [method top] and [method rank_of] order by, and [method merge] falls back
## to when it is not handed one. The tracker sets it.
var schema: DotStatsSchema = null


## Folds [param values] into a player's lifetime totals, stat by stat, by each stat's kind.
## Returns the player's totals afterwards, as [DotStatsValues].
##
## [param values] is a [DotStatsValues] or a [Dictionary] of readings; a dictionary goes
## through [method DotStatsValues.from_dictionary], which drops anything that is not a finite
## number. A stat [param p_schema] does not declare is skipped: there is no rule to merge it
## by. [param player_name] is kept beside the values, for a ranking somebody reads.
##
## [b]On failure, [code]error.context["unapplied"][/code] says what did not land[/b], as a
## dictionary of readings, when a store applies stat by stat and failed part-way. A caller
## retrying the whole delta would otherwise add a counter twice. Absent means none of it.
func merge(
	player_id: StringName, values: Variant, p_schema: DotStatsSchema = null, player_name: String = ""
) -> DotResult:
	var rules := p_schema if p_schema != null else schema
	if rules == null:
		return DotResult.fail(DotError.CODE_STATE, "A stats store needs a schema to merge by.")
	if schema == null:
		schema = rules
	if String(player_id) == "":
		return DotResult.fail(DotError.CODE_INVALID, "A player needs an id.")

	var incoming: DotStatsValues = null
	if values is DotStatsValues:
		incoming = values
	elif values is Dictionary:
		incoming = DotStatsValues.from_dictionary(values)
	else:
		return DotResult.fail(DotError.CODE_INVALID, "Values are a DotStatsValues or a Dictionary.")

	# Only what the schema can merge, and only finite numbers. A DotStatsValues built by
	# record() is both already; one built by hand might not be.
	var known := DotStatsValues.new()
	for id in incoming.values:
		var reading := float(incoming.values[id])
		if rules.has(id) and is_finite(reading):
			known.values[id] = reading

	return await _merge(player_id, known, rules, player_name)


## Every lifetime value a player holds. An empty set, never null, for a player with none.
func values_for(_player_id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "DotStatsStore.values_for() was not overridden.")


## One stat as a ranking, best first: an [Array] of
## [code]{"player": String, "name": String, "value": float, "rank": int}[/code].
func top(_stat_key: StringName, _limit: int = 10, _offset: int = 0) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "DotStatsStore.top() was not overridden.")


## A player's rank on one stat; 0 when they hold no value for it. Absent is not an error.
func rank_of(_stat_key: StringName, _player_id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "DotStatsStore.rank_of() was not overridden.")


## Forgets everything a player holds. For moderation, and for a player who asks.
## Returns whether there was anything to forget.
func remove_player(_player_id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "DotStatsStore.remove_player() was not overridden.")


## The merge itself, after [method merge] has checked and filtered. Override.
func _merge(
	_player_id: StringName, _incoming: DotStatsValues, _schema: DotStatsSchema, _player_name: String
) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "DotStatsStore._merge() was not overridden.")


## Whether lower is better for a stat, from its kind; an error for a stat nobody declared.
func _ordering(stat_key: StringName) -> DotResult:
	if schema == null:
		return DotResult.fail(DotError.CODE_STATE, "A stats store needs a schema to rank by.")
	var def := schema.find(stat_key)
	if def == null:
		# Not an empty ranking: a stat with no definition has no direction, and guessing
		# one renders a "fewest deaths" board upside down.
		return DotResult.fail(DotError.CODE_INVALID, "No such stat is declared.", String(stat_key))
	return DotResult.success(def.kind == DotStatsDef.Kind.LOWEST)


func describe() -> Dictionary:
	var script: Script = get_script()
	return {
		"implementation": String(script.get_global_name()) if script != null else "?",
		"schema": schema.size() if schema != null else 0,
	}
