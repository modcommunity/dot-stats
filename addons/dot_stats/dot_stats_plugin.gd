@tool
extends EditorPlugin

## Editor entry point for dot-stats. Registers inspector types only.
##
## No autoloads. A tracker belongs to a server, and a process running two servers
## — or a server and a client — has two of them.

const _ICON := "res://addons/dot_stats/icon_placeholder.svg"

const _TYPES := [
	[
		"DotStatsTracker",
		"Node",
		"res://addons/dot_stats/runtime/dot_stats_tracker.gd",
	],
	[
		"DotStatsClient",
		"Node",
		"res://addons/dot_stats/runtime/dot_stats_client.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for entry in _TYPES:
		remove_custom_type(entry[0])
