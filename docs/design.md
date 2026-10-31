# Design

What a stat is, the one rule every party follows, and the two surfaces that report one. The server-side store is [store.md](store.md); the site is [backbone.md](backbone.md).

## What this is, and what it is not

A **leaderboard** is one number per player, ordered; dot-leaderboard has those. A **stat** is many numbers per player, accumulated, and nothing here orders anything. "Most kills" is a board a game may publish over its `kills` stat, or a ranking the site derives on read; the stat is the fact and the board is a view of it.

The two addons do not import each other, and this one carries its own value set (`DotStatsValues`) rather than dot-leaderboard's `DotStatSet`, because the family rule is that naming an absent `class_name` fails to parse, and because the two differ on purpose: `DotStatSet` is additive everywhere and the caller picks "best" per call; here the rule comes from the definition.

**`Dot`-prefixed as `DotStats*`, not `DotStat*`**, because dot-leaderboard already owns `DotStatSet` and `class_name` is global.

## The kind is the whole contract

A stat's name, unit and decimals are presentation. The one thing every party that touches a value has to agree on (the server that counts it, the reporter that batches it, the backbone that stores it) is what happens when a new reading meets an old one. Four answers cover everything a game counts:

| Kind | On a new reading | For |
| --- | --- | --- |
| `COUNTER` | adds it | kills, jumps, metres, seconds played |
| `GAUGE` | replaces the held value | a level, a rank, a rating |
| `BEST` | keeps the higher | top speed, longest streak |
| `LOWEST` | keeps the lower | a personal best where lower wins |

A first reading stands as it is whatever the kind: a counter's first delta is its first total, and a `LOWEST` compared against an implicit zero could never be beaten.

**The same rule runs in four places, deliberately:** `DotStatsDef.merge`, the tracker's session and delta sets, the reporter's coalescing of one player's readings between flushes, and website-city's merge on arrival. That is what makes a report a *delta* rather than a total ("add 3", not "now has 40"), so two servers reporting one player add up rather than overwrite, and the order batches land in does not change the answer. Any two of those four disagreeing is a number that is wrong without anything having failed, which is why both suites test the rule directly and the backbone's verifier runs it against the database. A server-side store does not get to be a fifth copy ([store](store.md#the-rule-stays-in-one-place)).

**A kind never changes.** The backbone refuses a `define` that renames a stat's kind: a counter redefined as a gauge would have every held total reread as a reading. Declare a new key.

## The tracker

`DotStatsTracker` keeps two sets per player: the **session** (for the game's own HUD, never sent) and the **delta** since the last flush (what leaves). `flush()` declares the schema once, moves every delta into the reporter and sends. `end()` queues a player's last delta before forgetting them, and `_exit_tree` flushes, so a server that stops between reports does not lose the last interval of everybody's play.

**`report_to_backbone = false` means the reporter is never touched.** `_checkpoint` clears the delta and returns when reporting is off; otherwise a leave queues rows no flush will ever send and warns about them on every server that left reporting off, which is the default ([history](history.md)).

dot-server does not create a tracker; a game's module does, beside its `DotBackboneClient`, keying players by the scoped id dot-platform resolved and counting nothing for a session that has none. Most games have one in their `*_progress.gd`.

## Two surfaces, and which to use

| | `DotStatsTracker` | `DotStatsClient` |
| --- | --- | --- |
| Runs on | a server, or the app's own service | the game the player is holding |
| Credential | an integration token (`STATS_WRITE`) | the player's own access token |
| Files for | every player it sees | one player, the one signed in |
| Endpoint | `/api/integration/v1/stats/*` | `/api/app/v1/stats/*` |
| Trust | first-hand, revocable, audited | the player chose the numbers |

**They meet on one key.** A client files under the member's key for the scope `app:<id>`, exactly what an app-scoped credential's target resolves to, and exactly what `play/scope-key` hands a client for that scope. So a player's self-reported diary and their servers' figures are the same rows, and the app's service reads both with one call.

**A client cannot declare.** A definition is editorial and a kind is a contract; neither belongs to one player. The app declares, and a client's reading for an undeclared stat is refused.

Keep anything competitive on the tracker. `DotStatsClient` is for launches, time in menus, a longest session: a diary, not a scoreboard.

## Where the tracker runs

On the process that holds the integration credential: a dedicated server, or the app's own service. **Never in a client build.** An integration token in a client is a token in every player's hands, and a stat a client reports about itself is a stat it chose. That surface is `DotStatsClient`, with the player's own token.

## v2 declarations, cells, events and sessions

A declaration may add `type`, `min`/`max`, `max_rate`, up to two `breakdowns` (weapon, map, never crossed), a derived stat (ratio, difference, sum, per_minute over two stored stats, never stored), display hints and `source` (server or client). A v1 declaration loads unchanged and a schema version above 2 is refused. A breakdown cell is keyed `stat|axis:value` and merges by the stat's own kind through `DotStatsDef.merge`. `set_context` fills an axis a record omits, and `event()` runs the schema's `rules` (event to stat, `when`/`unless` tags, a value field or callback).

With `log_events` the tracker keeps append-only rows `{session, player, is_bot, stat, dims, value, t}` for `drain_events()`, and sessions are first-class (`session_info`, `session_ended`). A bot (`begin` meta `is_bot`, or `bot_check`) never carries a linked-user claim; `tmc_user` is kept only with `link_tmc_user`. The reporter freezes each batch under an id and resends it unchanged until acknowledged; define sends `source` in the site's upper case.

The reporter posts `stats/v2/submit`: `{v:2, batch, server?, sessions, players:[{player, bot, name, session, user?, stats, by}]}` (the site's stats-site-contract.md). Session rows ride the next batch (200 per request) and are frozen with it; a bot never carries `user`. `max_rate` is enforced in the tracker as a per-player, per-stat token bucket (`refused(..., "over_rate")`, `clock` is injectable). `DotStatsClient` refuses a `source=server` stat. The SQL store keys a row by (player, stat, dim): dim `""` is the total, `axis:value` a breakdown cell.

Seam: neither dot-game nor dot-bot calls the tracker yet. Whoever wires it passes `is_bot` in the `begin` meta or assigns `tracker.bot_check`.

## Deliberately not here

- **App-wide totals across servers.** Two servers' keys for one player are uncorrelatable by design. A per-app view per player exists only under the app scope key, which is the player's to ask for, and which `DotStatsClient` and an app-scoped tracker both use.
- **Server-level figures that are not about a player.** Rounds played, maps rotated: those are `DotBackboneClient.report_stats` and the site's own rollups.
- **Anti-cheat.** Refusals here are structural: NaN, an undeclared stat, an account-shaped id. Plausibility needs the game's context.
- **A tracker in dot-server.** A game's module builds one.

## Event feeds

`DotStatsEventFeed` turns a game's own events into tracker records. The game assigns Callables (`key_of`, `name_of`, `is_bot`, `extra`) and calls `report_kill` or `bind_kills`; the event shape, the bot flag, name resolution (a name equal to the key is no name, so a bot is never shown as its storage id) and refusal of suicides live there, and batching stays in the reporter. Hitzones, points and rank inputs are further `report_*` methods that resolve players through `actor()`.

## Rank
`DotStatsRank` produces one published GAUGE, **`rank_score`** (whole number, higher is better, `DotStatsRank.STAT_ID`; `declare(schema)` adds it, a game may file it under its own prefix via `stat_id`). The website orders a leaderboard by it and reads its history from the gauge. Two modes, chosen per app and per server: `weighted` (sum of `weight * stat`, or `weight * stat / per` for a ratio, optional per-term `cap`, then `offset` and `scale`; `min_stat`/`min_value` withhold a score until the player has played enough) and `elo` (`duel(winner, loser)` per kill, `elo_start` 1000, `elo_k` 24, `elo_floor`). Configuration is `configure_scoped({default, apps: {id}, servers: {id}}, app, server)` from JSON (`load_json`), or the cvar form `apply_cvar("elo")` / `apply_cvar("weighted:kills=1,deaths=-0.5")`; later blocks override earlier ones. Weighted mode needs lifetime figures: `DotStatsRank.combine(baseline, session_values)` adds this session to what a store held, then `publish(player, values)` files the gauge. `examples/rank_selftest.tscn` is the suite.

## Points

`DotStatsPoints` is one points score for any game: the game reports events (`award_kill`, `award`, `note_damage`, `survive`), the source table (kill, headshot, assist, streak, objective, survival, pickup, medal) holds the amounts and loads from JSON, and `record_fn` files each award with the tracker under the `declare`d stat. A client copy is filled with `mirror`. `examples/points_selftest.tscn` is the suite.
