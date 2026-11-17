class_name DotStatsStoreFile
extends DotStatsStoreMemory

## Lifetime values kept in one JSON file, for a server or an offline game with no database.
##
## [b]One write per flush, off the main thread.[/b] A merge only marks the file dirty; the next frame takes one snapshot and a worker serialises and writes it, so a tracker flush that merges 24 players is one write, not 24 in one frame. Call [method finish] before the owner goes away (the tracker does, on exit): it writes what is unwritten and waits for a write in flight. With [member write_behind] off every merge writes through at once, as before.

const CHANNEL := "stats.store"

## Where the file lives; a [code]user://[/code] path, so the web build keeps it too.
var path: String = "user://dot_stats.json"

## False writes the whole file inside every merge and remove (the old behaviour; a reader of the file sees each merge at once).
var write_behind: bool = true

## How many times the file has been written; suites count it.
var writes: int = 0

var _loaded: bool = false
var _dirty: bool = false
var _ticking: bool = false
var _task: int = -1
# Written by the worker, read on the main thread only after the task has completed.
var _written: Array = []

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
	_dirty = true
	if not write_behind:
		finish()
		return
	if _ticking:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		finish()
		return
	_ticking = true
	tree.process_frame.connect(_tick)


## Writes whatever is still unwritten, now, and waits for a write in flight. For shutdown: no frame may follow.
func finish() -> void:
	_collect(true)
	if _dirty:
		_dirty = false
		_write(_snapshot(), path, _written)
		_collect(true)
	_stop_ticking()


func _tick() -> void:
	if not _collect(false):
		return
	if not _dirty:
		_stop_ticking()
		return
	_dirty = false
	var rows := _snapshot()
	if DotPlatform.has_threads():
		_task = WorkerThreadPool.add_task(_write.bind(rows, path, _written), false, "stats file")
	else:
		_write(rows, path, _written)
		_collect(true)


func _stop_ticking() -> void:
	if not _ticking:
		return
	_ticking = false
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_tick):
		tree.process_frame.disconnect(_tick)


## Plain data only, so the worker shares nothing with the rows the next merge changes.
func _snapshot() -> Dictionary:
	var out := {}
	for id in _rows:
		var row: Dictionary = _rows[id]
		var values: DotStatsValues = row["values"]
		out[String(id)] = {"name": row["name"], "values": values.to_dictionary(), "cells": values.cells.duplicate()}
	return out


## False while a write is still running. [param wait] blocks until it is done.
func _collect(wait: bool) -> bool:
	if _task != -1:
		if not wait and not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _written.is_empty():
		return true
	var written: DotResult = _written.pop_back()
	_written.clear()
	writes += 1
	if not written.ok:
		# The figures stay in memory and the next merge retries; failing the merge would make the tracker re-queue a delta already folded in.
		_dirty = true
		DotLog.warn(CHANNEL, "could not write the stats file", {"path": path, "why": written.error.message})
		return true
	DotWeb.sync_filesystem()
	return true


static func _write(rows: Dictionary, to: String, result: Array) -> void:
	result.append(DotPaths.write_json(to, rows, true, true))
