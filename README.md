# dot-stats

Per-player statistics a game declares once and reports in batches. Counters, gauges, bests and lowests are merged by a rule the game states, and filed to the TMC back end without a server ever handing over an account id.

State the merge rule once per stat (add, replace or keep the better) and every party applies it the same way: the server counting, the reporter batching and the site storing.

## Install

1. Get [Godot 4.7](https://godotengine.org/download).
2. Either use [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons, or copy `addons/dot_stats/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-stats in *Project > Project Settings > Plugins*.

dot-core is the only dependency. [dot-auth](https://github.com/modcommunity/dot-auth) is optional and supplies the two clients (`DotBackboneClient` for a server, `DotAuthClient` for a player).

## Use

```gdscript
var schema := DotStatsSchema.new()
schema.define(&"kills").publish = true
schema.define(&"top_speed", DotStatsDef.Kind.BEST, "Top speed").publish = true
schema.define(&"level", DotStatsDef.Kind.GAUGE)          # kept, never reported

var tracker := DotStatsTracker.new()
tracker.schema = schema
tracker.report_to_backbone = true
tracker.reporter.client = backbone      # dot-auth's DotBackboneClient
add_child(tracker)

tracker.begin(player_key, display_name) # the scoped key, never the account id
tracker.record(player_key, &"kills")
tracker.record(player_key, &"top_speed", 41.2)
tracker.end(player_key)                 # reports the last delta, forgets them
```

Every `report_interval` seconds (default 30) and once more on shutdown, the tracker sends each player's delta since the last report, such as `{"kills": 3, "top_speed": 41.2}`. The site merges each by its kind.

## Lifetime totals on the server

```gdscript
var store := DotStatsStoreSql.new(driver)   # any dot-sql driver; or DotStatsStoreMemory
await store.open()                          # creates or migrates its table
tracker.store = store                       # before add_child
```

Each reported delta is also merged into the store by the same rule, so a server with no back end still keeps every player's totals. The store answers `values_for(player)`, `top(stat, limit, offset)` (a `LOWEST` ascending, the rest descending, ties sharing a rank), `rank_of(stat, player)` and `remove_player(player)`.

`DotStatsStoreSql` speaks SQLite, PostgreSQL and MySQL/MariaDB through [dot-sql](https://github.com/modcommunity/dot-sql), without needing it to parse. Writes are guarded by a revision, so two servers sharing a table add up instead of overwriting. A failed write is kept for the next flush and never counts a counter twice.

## Player-reported stats

A player's own client can report its own figures with the player's token and no integration credential:

```gdscript
var mine := DotStatsClient.new()
mine.schema = schema
mine.client = auth_client        # dot-auth's DotAuthClient
add_child(mine)

mine.record(&"launches")
var held := await mine.fetch_mine()
```

Both land on the same rows. Keep anything competitive on the server; this is for a diary.

## Stat catalogue file

`tools/export_site_defs.gd` writes a game's published stats as the site's `dot-stat-defs` JSON, from the schema the game really builds, so the site owner imports it instead of retyping it. Run it from the game project with Godot headless as a script, passing `--source` (a script path), `--method` (the function returning the `DotStatsSchema`) and `--out`.

| Option | Does |
| --- | --- |
| `--check` | Writes nothing and exits 1 when the file on disk is stale. |
| `--game <id>` | Pins the site app id. Left out by default so one file imports anywhere. |

The file is `DotStatsSchema.to_site_defs()`. A scaled `difference` is skipped with a warning, because the site's diff ignores scale.

## Testing

Import the project once, then run `examples/stats_selftest.tscn` headless with Godot. `examples/stats_sql_live.tscn` runs the SQL store against real databases through `../dot-sql/tools/test_live.sh`. More in [docs/](docs/README.md).

## Status and licence

Part of the TMC **dot-\*** family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/modcommunity/dot-stats/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the TMC platform is the web back end; you can use your own instead of TMC's.
