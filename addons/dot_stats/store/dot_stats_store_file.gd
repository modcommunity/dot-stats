class_name DotStatsStoreFile
extends DotStatsStoreMemory

## Lifetime values kept in one JSON file, for a server or an offline game with no database.

## Where the file lives; a [code]user://[/code] path, so the web build keeps it too.
var path: String = "user://dot_stats.json"

var _loaded: bool = false

func _init(p_path: String = "user://dot_stats.json") -> void:
	path = p_path


func _merge(
	player_id: StringName, incoming: DotStatsValues, p_schema: DotStatsSchema, player_name: String
) -> DotResult:
	var read := _load()
	if not read.ok:
		return read
	var res: DotResult = await super._merge(player_id, incoming, p_schema, player_name)
	if res.ok:
		_save()
	return res


func values_for(player_id: StringName) -> DotResult:
	var read := _load()
	if not read.ok:
		return read
	return await super.values_for(player_id)


func remove_player(player_id: StringName) -> DotResult:
	var read := _load()
	if not read.ok:
		return read
	var res: DotResult = await super.remove_player(player_id)
	_save()
	return res


func _load() -> DotResult:
	if _loaded:
		return DotResult.success(true)
	if FileAccess.file_exists(path):
		var read := DotPaths.read_json(path)
		# A file that exists and cannot be read is a failure, not an empty store: the next write would replace a player's career with nothing.
		if not read.ok:
			return read.wrap("Could not read the stats file.")
		if not (read.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "The stats file is an object.", path)
		for id in (read.value as Dictionary):
			var row: Variant = read.value[id]
			if not (row is Dictionary):
				continue
			var values := DotStatsValues.from_dictionary((row as Dictionary).get("values", {}))
			var cells: Variant = (row as Dictionary).get("cells", {})
			if cells is Dictionary:
				for key in cells:
					if (cells[key] is float or cells[key] is int) and is_finite(float(cells[key])):
						values.cells[str(key)] = float(cells[key])
			_rows[StringName(str(id))] = {"name": str((row as Dictionary).get("name", "")), "values": values}
	_loaded = true
	return DotResult.success(true)


func _save() -> void:
	var out := {}
	for id in _rows:
		var row: Dictionary = _rows[id]
		var values: DotStatsValues = row["values"]
		out[String(id)] = {"name": row["name"], "values": values.to_dictionary(), "cells": values.cells.duplicate()}
	var written := DotPaths.write_json(path, out, true, true)
	if not written.ok:
		# The figures stay in memory and the next merge retries; failing the merge would make the tracker re-queue a delta already folded in.
		DotLog.warn("stats.store", "could not write the stats file", {"path": path, "why": written.error.message})
		return
	DotWeb.sync_filesystem()
