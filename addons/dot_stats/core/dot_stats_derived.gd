@tool
class_name DotStatsDerived
extends Resource

## A figure computed from two stored stats on read, never stored or merged.

enum Op { RATIO, DIFFERENCE, SUM, PER_MINUTE }

@export var op: Op = Op.RATIO
## Stat id of the first input (the numerator).
@export var num: StringName = &""
## Stat id of the second input; for PER_MINUTE a DURATION stat in seconds.
@export var den: StringName = &""
## Multiplies the result: 100 turns a ratio into a percentage.
@export var scale: float = 1.0


static func op_from_name(name: String) -> int:
	var idx := Op.keys().find(name.to_upper())
	return idx if idx >= 0 else -1


func op_name() -> String:
	return Op.keys()[op]


## The value over [param values], or NAN when an input is missing or the divisor is zero.
##
## [param cell] is a breakdown cell key such as `weapon:rifle`, or "" for the total.
func compute(values: DotStatsValues, cell: String = "") -> float:
	if not values.has_cell(num, cell) or not values.has_cell(den, cell):
		return NAN
	var a := values.get_cell(num, cell)
	var b := values.get_cell(den, cell)
	match op:
		Op.RATIO:
			return NAN if b == 0.0 else a / b * scale
		Op.DIFFERENCE:
			return (a - b) * scale
		Op.SUM:
			return (a + b) * scale
		Op.PER_MINUTE:
			return NAN if b <= 0.0 else a / (b / 60.0) * scale
	return NAN


func to_dictionary() -> Dictionary:
	return {"op": op_name().to_lower(), "num": String(num), "den": String(den), "scale": scale}


static func from_dictionary(data: Dictionary) -> DotResult:
	var d := DotStatsDerived.new()
	var o := op_from_name(str(data.get("op", "")))
	if o < 0:
		return DotResult.fail(DotError.CODE_INVALID, "Unknown derived op.", str(data.get("op")))
	d.op = o as Op
	d.num = StringName(str(data.get("num", "")))
	d.den = StringName(str(data.get("den", "")))
	d.scale = float(data.get("scale", 1.0))
	if not is_finite(d.scale):
		return DotResult.fail(DotError.CODE_INVALID, "A derived scale must be finite.")
	if d.num == &"" or d.den == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A derived stat names its num and den.")
	return DotResult.success(d)
