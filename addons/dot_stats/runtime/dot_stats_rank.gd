class_name DotStatsRank
extends RefCounted
## One "rank_score" per player from declared stats (weighted formula) or from duels (Elo), chosen by configuration per app and per server.

const MODE_WEIGHTED := &"weighted"
const MODE_ELO := &"elo"

## The stat id the site orders leaderboards by; a published GAUGE, whole numbers, higher is better.
const STAT_ID := &"rank_score"

## Wire name of the stat, kept in a variable so a game can file it under its own prefix.
var stat_id: StringName = STAT_ID
var mode: StringName = MODE_WEIGHTED
## Weighted mode: rows of [code]{stat, weight, per?, cap?}[/code]. The term is [code]weight * value[/code], or [code]weight * value / per[/code] (a ratio, 0 when per is 0), clamped to [code]cap[/code] when positive.
var terms: Array = [
	{"stat": "kills", "weight": 1.0},
	{"stat": "deaths", "weight": -0.5},
	{"stat": "headshots", "weight": 0.5},
	{"stat": "points", "weight": 0.01},
]
## Added to the weighted sum, then the sum is multiplied by [member scale].
var offset: float = 0.0
var scale: float = 1.0
## Weighted mode: a score is withheld (not published) until the player has this much of [member min_stat].
var min_stat: StringName = &""
var min_value: float = 0.0
## Elo mode.
var elo_start: float = 1000.0
var elo_k: float = 24.0
var elo_floor: float = 0.0
## [code]func(player: Variant, stat: StringName, value: float)[/code] filing the gauge with a tracker.
var record_fn: Callable = Callable()

## Elo mode: player to rating.
var ratings: Dictionary = {}


## Adds the published rank stat to [param schema].
static func declare(schema: DotStatsSchema, id: StringName = STAT_ID, display: String = "Rank score") -> DotStatsDef:
	var def := DotStatsDef.make(id, DotStatsDef.Kind.GAUGE, display)
	def.decimals = 0
	def.publish = true
	schema.stats.append(def)
	return def


## Reads mode, terms and options; unknown keys are ignored.
func configure(cfg: Dictionary) -> void:
	mode = StringName(str(cfg.get("mode", mode)))
	var t: Variant = cfg.get("terms", null)
	if t is Array:
		terms = (t as Array).duplicate(true)
	offset = float(cfg.get("offset", offset))
	scale = float(cfg.get("scale", scale))
	min_stat = StringName(str(cfg.get("min_stat", min_stat)))
	min_value = float(cfg.get("min_value", min_value))
	elo_start = float(cfg.get("elo_start", elo_start))
	elo_k = float(cfg.get("elo_k", elo_k))
	elo_floor = float(cfg.get("elo_floor", elo_floor))


## Applies the shared defaults, then the app's block, then the server's block. [param cfg] is [code]{default?, apps?: {id: block}, servers?: {id: block}}[/code].
func configure_scoped(cfg: Dictionary, app: String = "", server: String = "") -> void:
	var base: Variant = cfg.get("default", null)
	if base is Dictionary:
		configure(base)
	var apps: Variant = cfg.get("apps", {})
	if apps is Dictionary and (apps as Dictionary).get(app) is Dictionary:
		configure((apps as Dictionary)[app])
	var servers: Variant = cfg.get("servers", {})
	if servers is Dictionary and (servers as Dictionary).get(server) is Dictionary:
		configure((servers as Dictionary)[server])


## Loads [method configure_scoped] from a JSON file.
func load_json(path: String, app: String = "", server: String = "") -> DotResult:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return DotResult.fail(DotError.CODE_IO, "No rank file at %s." % path)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return DotResult.fail(DotError.CODE_PARSE, "%s is not a JSON object." % path)
	configure_scoped(parsed, app, server)
	return DotResult.success()


## The cvar form: "weighted", "elo", or "weighted:kills=1,deaths=-0.5,headshots=0.5". Returns false on an unknown mode.
func apply_cvar(text: String) -> bool:
	var parts := text.strip_edges().split(":", false, 1)
	if parts.is_empty():
		return false
	var m := StringName(parts[0].strip_edges().to_lower())
	if m != MODE_WEIGHTED and m != MODE_ELO:
		return false
	mode = m
	if parts.size() > 1:
		var rows: Array = []
		for pair in parts[1].split(",", false):
			var kv := pair.split("=", false)
			if kv.size() == 2 and kv[1].is_valid_float():
				rows.append({"stat": kv[0].strip_edges(), "weight": kv[1].to_float()})
		if not rows.is_empty():
			terms = rows
	return true


func to_dictionary() -> Dictionary:
	return {
		"mode": String(mode), "terms": terms.duplicate(true), "offset": offset, "scale": scale,
		"min_stat": String(min_stat), "min_value": min_value,
		"elo_start": elo_start, "elo_k": elo_k, "elo_floor": elo_floor,
	}


## Weighted score of [param values] (stat id string or StringName to number); stats a term names that are missing count as 0.
func weighted(values: Dictionary) -> float:
	var sum := offset
	for row in terms:
		var term: Dictionary = row
		var v := _value(values, term.get("stat", ""))
		var per: Variant = term.get("per", null)
		if per != null and str(per) != "":
			var d := _value(values, per)
			v = v / d if d != 0.0 else 0.0
		var contribution := float(term.get("weight", 0.0)) * v
		var cap := float(term.get("cap", 0.0))
		if cap > 0.0:
			contribution = clampf(contribution, -cap, cap)
		sum += contribution
	return sum * scale


## Whether [param values] has enough activity to publish a weighted score.
func qualifies(values: Dictionary) -> bool:
	return min_stat == &"" or _value(values, min_stat) >= min_value


## Elo mode: the rating of [param player], starting at [member elo_start].
func rating_of(player: Variant) -> float:
	return float(ratings.get(player, elo_start))


## Elo mode: seeds a stored rating, e.g. the lifetime figure read back from a store.
func seed_rating(player: Variant, rating: float) -> void:
	ratings[player] = rating


## Elo mode: [param winner] beat [param loser] (a kill). Returns the points moved, and files both gauges.
func duel(winner: Variant, loser: Variant, weight: float = 1.0) -> float:
	if winner == loser:
		return 0.0
	var rw := rating_of(winner)
	var rl := rating_of(loser)
	var expected := 1.0 / (1.0 + pow(10.0, (rl - rw) / 400.0))
	var moved := elo_k * weight * (1.0 - expected)
	ratings[winner] = rw + moved
	ratings[loser] = maxf(elo_floor, rl - moved)
	_file(winner, float(ratings[winner]))
	_file(loser, float(ratings[loser]))
	return moved


## The published figure for [param player] in the current mode, or -1.0 when withheld. Weighted mode takes [param values] (lifetime plus session).
func score(player: Variant, values: Dictionary = {}) -> float:
	if mode == MODE_ELO:
		return rating_of(player)
	if not qualifies(values):
		return -1.0
	return weighted(values)


## Weighted mode: files [method score] as a gauge (rounded). Elo files itself in [method duel]. Returns what was filed, or -1.0.
func publish(player: Variant, values: Dictionary) -> float:
	var s := score(player, values)
	if s < 0.0:
		return -1.0
	_file(player, s)
	return s


## Lifetime values plus this session's, for [method publish]. Counters add; the caller passes only counters.
static func combine(baseline: Dictionary, session: DotStatsValues) -> Dictionary:
	var out := {}
	for k in baseline:
		out[str(k)] = float(baseline[k])
	var mine := session.to_dictionary()
	for k in mine:
		out[str(k)] = float(out.get(str(k), 0.0)) + float(mine[k])
	return out


func forget(player: Variant) -> void:
	ratings.erase(player)


func reset() -> void:
	ratings.clear()


func describe() -> Dictionary:
	var out := to_dictionary()
	out["ratings"] = ratings.duplicate()
	return out


func _file(player: Variant, value: float) -> void:
	if record_fn.is_valid():
		record_fn.call(player, stat_id, roundf(value))


func _value(values: Dictionary, id: Variant) -> float:
	var s := str(id)
	if values.has(s):
		return float(values[s])
	if values.has(StringName(s)):
		return float(values[StringName(s)])
	return 0.0
