extends Node
## Offline suite for DotStatsPoints. godot --headless --path . res://examples/points_selftest.tscn

var _passed := 0
var _failed := 0
var _filed := 0.0
var _seen: Array = []


func _ready() -> void:
	var pts := DotStatsPoints.new()
	pts.record_fn = func(_p: Variant, _s: StringName, v: float) -> void: _filed += v
	pts.awarded.connect(func(p: Variant, s: StringName, a: int, t: int) -> void: _seen.append([p, s, a, t]))

	_check(pts.award(1, &"kill") == 100 and int(pts.totals[1]) == 100, "a kill pays the configured amount")
	_check(is_equal_approx(_filed, 100.0), "the award is filed through record_fn")
	_check(pts.award(1, &"nothing") == 0 and pts.award(1, &"kill", 0.0) == 0, "an unknown source or zero scale pays nothing")
	pts.configure({"sources": {"kill": 10, "headshot": 5, "assist": 3, "streak": 2}, "streak_cap": 3})
	_check(pts.award(2, &"kill") == 10, "configure replaces an amount")

	pts.note_damage(3, 9, 30.0, 1.0)
	pts.note_damage(4, 9, 5.0, 1.0)
	pts.note_damage(2, 9, 50.0, 1.0)
	_check(pts.assisters(2, 9, 2.0) == [3], "assist: enough damage, not the killer")
	_check(pts.assisters(2, 9, 99.0).is_empty(), "assist: expires with the window")
	var got := pts.award_kill(2, 9, 2.0, true, false, 9)
	_check(got == 10 + 5 + 2 * 3, "kill + headshot + streak capped at 3 steps (%d)" % got)
	_check(int(pts.totals.get(3, 0)) == 3, "the assister was paid")
	_check(pts.assisters(2, 9, 2.0).is_empty(), "damage is forgotten after the kill")

	pts.configure({"sources": {"survival": 4}, "survival_interval_sec": 10.0})
	_check(pts.survive(5, 25.0) == 8 and pts.survive(5, 5.0) == 4, "survival pays per interval and carries the remainder")
	pts.mirror(7, &"kill", 10, 40)
	_check(int(pts.totals[7]) == 40 and _seen.back()[3] == 40, "a client mirror sets the total")
	var copy := DotStatsPoints.new()
	copy.configure(JSON.parse_string(JSON.stringify(pts.to_dictionary())))
	_check(copy.sources[&"kill"] == 10 and copy.streak_cap == 3, "config round-trips through JSON")
	var schema := DotStatsSchema.new()
	var def := DotStatsPoints.declare(schema)
	_check(schema.find(&"points") == def and def.publish, "declare adds a published stat")
	pts.forget(2)
	_check(not pts.totals.has(2), "forget drops a player")

	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)
