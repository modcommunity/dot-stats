# Reporting to the backbone

`DotStatsReporter`, which credential files whose figures, the pseudonym rule, and the site's half. The family's backbone rules are in [backbone.md](../../../docs/backbone.md).

## The client is anything with `post_integration`

`DotStatsReporter` calls `post_integration(path, body)` on an object it is handed: the generic hook dot-auth's `DotBackboneClient` exposes, which stamps `ts` (Unix **seconds**) and a `nonce`, adds the bearer header and rate-limits locally. So authentication lives in one place, this addon does not know a token exists, and **dot-auth is not a dependency**: naming `DotBackboneClient` would make this addon fail to parse without it. It is the same seam dot-leaderboard's reporter uses, so a game wires one client and both report through it.

## Three properties, each the answer to a lost report

- **Coalesced, by player.** A player who scored forty times between flushes is one row saying forty. The queue is bounded by *players*, not readings, and past the bound the oldest player is dropped; an active player is re-inserted at the newest end on every reading, so the row somebody is waiting to see is the last to go.
- **A failed flush keeps the queue.** Rows are removed only after the backbone said yes; re-queueing on failure would reorder against a flush already in progress. A 403 is logged with the scope it needs (`STATS_WRITE`) rather than retried in the log's face, and kept.
- **Publishing is opt-in per stat.** `DotStatsDef.publish` is off by default, so a game counts something privately by leaving it alone. An unpublished or undeclared stat in a reading is skipped with a warning the first time, because the backbone would refuse the whole batch for it.

## Which credential

Nothing in a body names an app or a server: **the token decides whose stats these are.** `DotAuthConfig.integration_token` holding an **app-scoped** integration files the game's own figures; a **server-scoped** one files that server's. Both are created at Account → Integrations on the site, against an item the member owns: a server they added or claimed, or an app they own. The addon is the same either way.

## The player id is a pseudonym, and the reporter enforces it

The backbone's `player` is "whatever the reporting server uses to mean this player on this server": the per-scope key dot-user's `DotUserScope` derives, or the one `POST /api/app/v1/play/scope-key` hands a client on join. It is **never** a site account id, and the backbone never resolves it to one; a server asserting "this player is that member" is a server that can put any figure against any account.

The backbone's identifier alphabet allows a colon, so a dot-auth account uid (`backbone:clx8f…`) would pass its schema and would be filed. `DotStatsReporter` refuses one before it leaves the process, because a server that filed those would hand every operator a stable global identifier for every player (the thing the scoped key exists to prevent), and it would do so with nothing failing. The identity comes from dot-auth, the *key* a stat is filed under comes from dot-user's scoping of it, and this addon refuses to confuse the two.

A consequence: because the key is scoped to the credential, a player on two servers of one game is two keys nothing can join. A game-wide figure per player exists only for a player who asked for the game-wide scope. That is the privacy property, not a gap.

## The backbone's half

website-city: `src/types/integration/stats.ts` (the contract), `src/lib/integration/stats.ts` (the rules), and four routes under `/api/integration/v1/stats/`:

| Endpoint | Scope | |
| --- | --- | --- |
| `POST /stats/define` | `STATS_WRITE` | declare; idempotent; a kind never changes |
| `POST /stats/submit` | `STATS_WRITE` | file deltas, up to 50 players, merged by kind |
| `GET /stats/player` | `STATS_READ` | every value one player holds |
| `GET /stats/top` | `STATS_READ` | one stat as a ranking, ranks derived |

and the app API's own under `/api/app/v1/stats/`, spoken by a player's own token rather than a credential (`submit`, `me`, `top`, `defs`).

The tables are `PlayerStatDef` and `PlayerStat`, declared-schema rows keyed by the credential's owner, and not columns on `ServerUser`, for reasons written on the model: that table is past a hundred million rows, is closed to new indexes, and every column on it is charged to every roster row the scanner writes for ever. `scripts/verify-stats-integration.ts` runs the whole contract against a live server, including the merge rule against the database.
