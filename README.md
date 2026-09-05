This is the **statistics** asset for TMC's **Dot** collection. A game says once what it counts, and this files those numbers to the TMC backbone without a server ever handing over an account id.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Per-Player Statistics
**Per-player statistics a game declares once and reports in batches.** Counters,
gauges, bests and lowests, merged by a rule the game states, filed to the TMC
backbone under an app or a server integration.

## Why

A leaderboard is one number per player, ordered. Most of what a game counts is not
that: kills, deaths, jumps, metres, seconds played, a top speed, a level. Those are
many numbers per player, accumulated, and the only thing anybody has to agree on is
how a new reading meets an old one — add it, replace it, or keep the better. State
that once per stat and every party can apply it: the server counting, the reporter
batching, the site storing.

## Installing

Copy `addons/dot_stats/` and [`dot-core`](../dot-core)'s `addons/dot_core/` into your
project and enable dot-stats in *Project → Project Settings → Plugins*.

[dot-auth](../dot-auth) supplies both clients — `DotBackboneClient` for a server's
reporting and `DotAuthClient` for a player's own — and is optional; neither is named
anywhere in the source.

## Five minutes

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

tracker.begin(player_key, display_name) # the SCOPED key, never the account id
tracker.record(player_key, &"kills")
tracker.record(player_key, &"top_speed", 41.2)
tracker.end(player_key)                 # reports the last delta, forgets them
```

Every 30 seconds — and once more on the way down — the tracker sends each player's
delta since the last report: `{"kills": 3, "top_speed": 41.2}`. The site merges each
by its kind.

## The other surface

A player's own client reports its own figures, with the player's token and no
integration credential anywhere near it:

```gdscript
var mine := DotStatsClient.new()
mine.schema = schema
mine.client = auth_client        # dot-auth's DotAuthClient
add_child(mine)

mine.record(&"launches")
var held := await mine.fetch_mine()
```

Both land on the same rows, because a client files under the member's key for the
app's own scope. Keep anything competitive on the server; this is for a diary.

## Validating

```bash
godot --headless --path . res://examples/stats_selftest.tscn
```

See [CLAUDE.md](CLAUDE.md) for the design, the two surfaces, and what is
deliberately left out.
