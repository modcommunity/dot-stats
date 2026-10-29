# dot-stats

Per-player statistics a game declares once and reports to the TMC backbone in batches: counters, gauges, bests and lowests, keyed by a pseudonymous player id, filed under an app or a server integration, and optionally kept on the server in a store.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to stats. The reasoning is in [docs/](docs/README.md).

**The distributable is `addons/dot_stats/`.** It requires dot-core and nothing else (symlinked, `.gitignore`). dot-auth, dot-leaderboard and dot-sql are never named; dot-sql is linked only for the suites.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | `DotStatsDef`, `DotStatsSchema`, `DotStatsValues`, `DotStatsTracker`, `DotStatsClient` |
| [docs/store.md](docs/store.md) | any `DotStatsStore`, `DotStatsSqlSchema` |
| [docs/backbone.md](docs/backbone.md) | `DotStatsReporter`, credentials, anything the site receives |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_stats/core/` | `DotStatsDef` (one stat; `merge()` is the rule), `DotStatsSchema` (every stat a game keeps; the wire shape of define), `DotStatsValues` (one player's values; refuses NaN) |
| `addons/dot_stats/net/` | `DotStatsReporter`: coalesces per player, batches, keeps its queue on failure |
| `addons/dot_stats/store/` | `DotStatsStore` (abstract; ordering from the kind), memory, SQL via dot-sql, `DotStatsSqlSchema` |
| `addons/dot_stats/runtime/` | `DotStatsTracker` (the Node: begin/record/end per player, a timer, a final flush), `DotStatsClient` (a player reporting their own figures) |
| `examples/stats_selftest.tscn` | the suite; all offline |
| `examples/stats_sql_live.tscn` | the SQL store against real databases |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/stats_selftest.tscn`.
- Anything in the SQL store: `../dot-sql/tools/test_live.sh . res://examples/stats_sql_live.tscn` (SQLite always; Postgres and MySQL with `DOT_SQL_PG_DSN` / `DOT_SQL_MYSQL_DSN`).
- The backbone client is faked one level above HTTP (a class with `post_integration`), which is the seam the addon promises.
- **Add a case for any change to the merge rule, the coalescing or the queue**: there a bug is a wrong number, not a crash.

## Rules that bite

- The kind is the contract: `COUNTER` adds, `GAUGE` replaces, `BEST` keeps higher, `LOWEST` keeps lower; a first reading stands. A kind never changes; declare a new key. [design](docs/design.md#the-kind-is-the-whole-contract)
- The merge rule lives in `DotStatsDef.merge` and runs in the tracker, the reporter and the site; reports are deltas. Never spell it again, in SQL or anywhere. [design](docs/design.md#the-kind-is-the-whole-contract)
- `DotStats*`, never `DotStat*`, and never dot-leaderboard's `DotStatSet`. [design](docs/design.md#what-this-is-and-what-it-is-not)
- `report_to_backbone = false` never touches the reporter. [design](docs/design.md#the-tracker)
- The tracker runs only where the integration credential is; never in a client build. Competitive figures stay on the tracker; `DotStatsClient` is a diary and cannot declare. [design](docs/design.md#two-surfaces-and-which-to-use)
- A store gets the same deltas at the same checkpoint as the reporter; assign it before `add_child`. [store](docs/store.md#fed-the-same-deltas-at-the-same-moment)
- The SQL store reads, folds with `merge`, and writes guarded by `revision`; a first value is a plain INSERT. [store](docs/store.md#the-rule-stays-in-one-place)
- A partial store failure names `unapplied`, and only that is re-queued, under newer checkpoints. [store](docs/store.md#a-partial-failure-names-what-did-not-land)
- Ranking direction comes from the kind; ties share a rank; ranking an undeclared stat is refused. [store](docs/store.md#ordering-comes-from-the-kind)
- The reporter coalesces per player, bounds by players dropping the oldest, keeps its queue on failure, and logs a 403 with `STATS_WRITE`. [backbone](docs/backbone.md#three-properties-each-the-answer-to-a-lost-report)
- `publish` is off by default per stat; unpublished or undeclared readings are skipped with one warning. [backbone](docs/backbone.md#three-properties-each-the-answer-to-a-lost-report)
- The player id is a scoped pseudonym; the reporter refuses an account-shaped uid before it leaves the process. [backbone](docs/backbone.md#the-player-id-is-a-pseudonym-and-the-reporter-enforces-it)
- v2 declarations add `type`, `min`/`max`, `max_rate`, up to two `breakdowns` (weapon, map; never crossed), a derived stat (ratio, difference, sum, per_minute over two stored stats, never stored), display hints and `source` (server or client; the site refuses client submissions for server stats). A v1 declaration loads unchanged.
- Breakdown cells merge by the stat's own kind; `set_context` supplies axes a record omits, and `event()` runs `rules` (event to stat, `when`/`unless` tags, a value field or callback).
- With `log_events`, `drain_events()` returns append-only rows `{session, player, is_bot, stat, dims, value, t}`; sessions are first-class (`session_info`, `session_ended`). Bots (`begin` meta `is_bot` or `bot_check`) never carry a linked-user claim; `tmc_user` is kept only with `link_tmc_user`.
- The reporter posts `stats/v2/submit` (sessions, per-player `by` cells, frozen batch id resent unchanged). The tracker enforces `max_rate`; `DotStatsClient` refuses server-source stats; the SQL store has a `dim` column (key player, stat, dim). dot-game and dot-bot do not call the tracker yet, so they must pass `is_bot` in `begin` meta or set `bot_check`.
- The reporter sends a batch id and resends an unacknowledged batch unchanged under the same id.

Deliberately not here: app-wide totals across servers, server-level figures, anti-cheat, a tracker in dot-server. [design](docs/design.md#deliberately-not-here)
