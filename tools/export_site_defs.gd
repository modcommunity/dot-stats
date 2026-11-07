extends SceneTree

## Writes a game's published stats as the site's `dot-stat-defs` JSON, from the schema the game
## really builds. Run inside the game project:
##   godot --headless --path . --script ../dot-stats/tools/export_site_defs.gd -- \
##     --source res://game/x_progress.gd --method schema --out deployment/stat-defs.json [--check] [--game 12]
## A stat with an empty format has no "format" key; per_minute is written as ratio with scale x60 and difference as diff
## (a scaled difference is skipped with a warning: the site's diff ignores scale).
## --check writes nothing and exits 1 if the file on disk differs, so a suite can hold the two together.

func _init() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var source := str(args.get("source", ""))
	var method := str(args.get("method", "schema"))
	var out_path := str(args.get("out", "deployment/stat-defs.json"))
	var script := load(source) as Script
	if script == null or not script.has_method(method):
		printerr("export_site_defs: %s has no static %s()" % [source, method])
		quit(2)
		return
	var schema := script.call(method) as DotStatsSchema
	var valid := schema.validate()
	if not valid.ok:
		printerr("export_site_defs: schema invalid: %s" % valid.message)
		quit(2)
		return
	for d in schema.published():
		if schema.site_unsupported(d):
			printerr("export_site_defs: skipped %s (a scaled difference has no site mapping)" % d.id)
	var text := JSON.stringify(schema.to_site_defs(int(args.get("game", 0))), "\t", false) + "\n"
	if args.has("check"):
		var have := FileAccess.get_file_as_string(out_path)
		if have != text:
			printerr("export_site_defs: %s is out of date; re-run without --check" % out_path)
			quit(1)
			return
		print("export_site_defs: %s is current (%d stats)" % [out_path, schema.published().size()])
		quit(0)
		return
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("export_site_defs: cannot write %s" % out_path)
		quit(2)
		return
	f.store_string(text)
	f.close()
	print("export_site_defs: wrote %s (%d stats)" % [out_path, schema.published().size()])
	quit(0)


func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var k := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[k] = argv[i + 1]
				i += 1
			else:
				out[k] = true
		i += 1
	return out
