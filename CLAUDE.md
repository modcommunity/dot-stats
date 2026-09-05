# dot-stats

Per-player statistics a game declares once and reports to the TMC backbone in
batches. Counters, gauges, bests and lowests, keyed by a pseudonymous player id,
filed under an app or a server integration.

**The distributable is `addons/dot_stats/`.** It requires [dot-core](../dot-core),
a separate repository, and nothing else.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## What this is, and what it is not

A **leaderboard** is one number per player, ordered. dot-leaderboard has those. A
**stat** is many numbers per player, accumulated, and nothing here orders anything.
"Most kills" is a board a game may publish over its `kills` stat, or a ranking the
site derives on read; the stat is the fact and the board is a view of it. The two
addons do not import each other and this one carries its own value set
(`DotStatsValues`) rather than dot-leaderboard's `DotStatSet`, because the family
rule is that naming an absent `class_name` fails to parse — and because the two
differ on purpose: `DotStatSet` is additive everywhere and the caller picks "best"
per call; here the rule comes from the definition.

**`Dot`-prefixed as `DotStats*`, not `DotStat*`**, because dot-leaderboard already
owns `DotStatSet` and `class_name` is global.

## The one idea: the kind is the whole contract

A stat's name, unit and decimals are presentation. The one thing every party that
touches a value has to agree on — the server that counts it, the reporter that
batches it, the backbone that stores it — is what happens when a new reading meets
an old one. Four answers cover everything a game counts:

| Kind | On a new reading | For |
| --- | --- | --- |
| `COUNTER` | adds it | kills, jumps, metres, seconds played |
| `GAUGE` | replaces the held value | a level, a rank, a rating |
| `BEST` | keeps the higher | top speed, longest streak |
| `LOWEST` | keeps the lower | a personal best where lower wins |

A first reading stands as it is whatever the kind: a counter's first delta is its
first total, and a `LOWEST` compared against an implicit zero could never be beaten.

**The same rule runs in four places, deliberately:** `DotStatsDef.merge`, the
tracker's session and delta sets, the reporter's coalescing of one player's readings
between flushes, and website-city's `PlayerStatMerge` on arrival. That is what makes
a report a *delta* rather than a total — "add 3", not "now has 40" — so two servers
reporting one player add up rather than overwrite, and the order batches land in
does not change the answer. Any two of those four disagreeing is a number that is
wrong without anything having failed, which is why both suites test the rule
directly and the backbone's verifier runs it against the database.

**A kind never changes.** The backbone refuses a `define` that renames a stat's
kind: a counter redefined as a gauge would have every held total reread as a
reading. Declare a new key.

## The pieces

```
addons/dot_stats/
  core/
    dot_stats_def.gd      One stat: id, kind, presentation, publish. merge() is the rule.
    dot_stats_schema.gd   Every stat a game keeps. Validated; the wire shape of define.
    dot_stats_values.gd   One player's values, merged by a schema. Refuses NaN.
  net/
    dot_stats_reporter.gd Coalesces per player, batches, keeps its queue on failure.
  runtime/
    dot_stats_tracker.gd  The Node: begin/record/end per player, a timer, a final flush.
    dot_stats_client.gd   The other surface: a player reporting their OWN figures.
```

`DotStatsTracker` keeps two sets per player: the **session** (for the game's own
HUD, never sent) and the **delta** since the last flush (what leaves). `flush()`
declares the schema once, moves every delta into the reporter and sends. `end()`
queues a player's last delta before forgetting them, and `_exit_tree` flushes, so a
server that stops between reports does not lose the last interval of everybody's play.

## Two surfaces, and which to use

| | `DotStatsTracker` | `DotStatsClient` |
| --- | --- | --- |
| Runs on | a server, or the app's own service | the game the player is holding |
| Credential | an integration token (`STATS_WRITE`) | the player's own access token |
| Files for | every player it sees | one player, the one signed in |
| Endpoint | `/api/integration/v1/stats/*` | `/api/app/v1/stats/*` |
| Trust | first-hand, revocable, audited | the player chose the numbers |

**They meet on one key.** A client files under the member's key for the scope
`app:<id>` — exactly what an app-scoped credential's target resolves to, and
exactly what `play/scope-key` hands a client for that scope. So a player's
self-reported diary and their servers' figures are the same rows, and the app's
service reads both with one call.

**A client cannot declare.** A definition is editorial and a kind is a contract;
neither belongs to one player. The app declares, and a client's reading for an
undeclared stat is refused.

Keep anything competitive on the tracker. `DotStatsClient` is for launches, time
in menus, a longest session — a diary, not a scoreboard.

## Reporting to the backbone

`DotStatsReporter` calls `post_integration(path, body)` on an object it is handed —
the generic hook dot-auth's `DotBackboneClient` exposes, which stamps `ts` (Unix
**seconds**) and a `nonce`, adds the bearer header and rate-limits locally. So
authentication lives in one place, this addon does not know a token exists, and
**dot-auth is not a dependency**: naming `DotBackboneClient` would make this addon
fail to parse without it. It is the same seam dot-leaderboard's reporter uses, so a
game wires one client and both report through it.

Three properties the reporter has, each the answer to a way a report gets lost:

- **Coalesced, by player.** A player who scored forty times between flushes is one
  row saying forty. The queue is bounded by *players*, not readings, and past the
  bound the oldest player is dropped — an active player is re-inserted at the newest
  end on every reading, so the row somebody is waiting to see is the last to go.
- **A failed flush keeps the queue.** Rows are removed only after the backbone said
  yes; re-queueing on failure would reorder against a flush already in progress. A
  403 is logged with the scope it needs (`STATS_WRITE`) rather than retried in the
  log's face, and kept.
- **Publishing is opt-in per stat.** `DotStatsDef.publish` is off by default, so a
  game counts something privately by leaving it alone. An unpublished or undeclared
  stat in a reading is skipped with a warning the first time, because the backbone
  would refuse the whole batch for it.

### Which credential

Nothing in a body names an app or a server: **the token decides whose stats these
are.** `DotAuthConfig.integration_token` holding an **app-scoped** integration files
the game's own figures; a **server-scoped** one files that server's. Both are
created at Account → Integrations on the site, against an item the member owns — a
server they added or claimed, or an app they own. Apps are admin-created today, so
until games can be submitted the app-scoped path is the publisher's; the addon is
the same either way.

### The player id is a pseudonym, and the reporter enforces it

The backbone's `player` is "whatever the reporting server uses to mean this player
on this server" — the per-scope key dot-user's `DotUserScope` derives, or the one
`POST /api/app/v1/play/scope-key` hands a client on join. It is **never** a site
account id, and the backbone never resolves it to one; a server asserting "this
player is that member" is a server that can put any figure against any account.

The backbone's identifier alphabet allows a colon, so a dot-auth account uid
(`backbone:clx8f…`) would pass its schema and would be filed. `DotStatsReporter`
refuses one before it leaves the process, because a server that filed those would
hand every operator a stable global identifier for every player — the thing the
scoped key exists to prevent — and it would do so with nothing failing. This is the
link to the auth system: the identity comes from dot-auth, the *key* a stat is filed
under comes from dot-user's scoping of it, and this addon refuses to confuse the two.

A consequence worth knowing: because the key is scoped to the credential, a player
on two servers of one game is two keys nothing can join. A game-wide figure per
player exists only for a player who asked for the game-wide scope. That is the
privacy property, not a gap.

## Where it runs

On the process that holds the integration credential: a dedicated server, or the
app's own service. **Never in a client build.** An integration token in a client is
a token in every player's hands, and a stat a client reports about itself is a stat
it chose. A client-reported figure — "I launched the game" — is a different surface
(`/api/app/v1/*`, with the player's own token) and is deliberately not here.

## The backbone's half

website-city, `src/types/integration/stats.ts` (the contract), `src/lib/integration/stats.ts`
(the rules), and four routes under `/api/integration/v1/stats/`:

| Endpoint | Scope | |
| --- | --- | --- |
| `POST /stats/define` | `STATS_WRITE` | declare; idempotent; a kind never changes |
| `POST /stats/submit` | `STATS_WRITE` | file deltas, up to 50 players, merged by kind |
| `GET /stats/player` | `STATS_READ` | every value one player holds |
| `GET /stats/top` | `STATS_READ` | one stat as a ranking, ranks derived |

and three on the app API, spoken by a player's own token rather than a
credential: `POST /stats/submit`, `GET /stats/me`, `GET /stats/top`.

The tables are `PlayerStatDef` and `PlayerStat`, declared-schema rows keyed by the
credential's owner — and not columns on `ServerUser`, for reasons written on the
model: that table is past a hundred million rows, is closed to new indexes, and
every column on it is charged to every roster row the scanner writes for ever.
`scripts/verify-stats-integration.ts` runs the whole contract against a live server,
including the merge rule against the database.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 89 checks, all offline. Exits non-zero on any failure.
godot --headless --path . res://examples/stats_selftest.tscn
```

The backbone client is faked one level above HTTP — a class with a
`post_integration` method — which is exactly the seam the addon promises. Add a case
for any change to the merge rule, the coalescing or the queue; those are the ones
where a bug is a wrong number rather than a crash.

## Things deliberately not here

- **App-wide totals across servers.** Two servers' keys for one player are
  uncorrelatable by design. A per-app view per player exists only under the app
  scope key, which is the player's to ask for — which is what `DotStatsClient`
  and an app-scoped tracker both use.
- **Server-level figures that are not about a player.** Rounds played, maps
  rotated: those are `DotBackboneClient.report_stats` and the site's own rollups.
- **Client-reported stats.** See "Where it runs".
- **Anti-cheat.** Refusals here are structural — NaN, an undeclared stat, an
  account-shaped id. Plausibility needs the game's context.
- **A wire for dot-server.** dot-server does not create a tracker of its own; a
  game's module does. `dot-2d-hungry`'s is the worked example — it builds one
  beside its `DotBackboneClient`, keys players by the scoped id dot-platform
  resolved, and counts nothing for a session that has none.
