# Lifetime totals on the server: the store

Without a store the tracker keeps a session and a delta and nothing else, and the totals live only on the backbone. A server without one (a LAN, a community that has not linked an integration, a game in development) loses every number at the end of every session.

## Fed the same deltas at the same moment

`DotStatsTracker.store` is an optional `DotStatsStore` (untyped, so a game can hand it anything with the same `merge`), fed **the same deltas at the same moment** the reporter is: at a checkpoint (a flush, a leave, shutdown). So a server with both keeps both, and the two cannot disagree about which readings they were told of. With only a store the flush timer still runs; assign it before `add_child`.

## The rule stays in one place

Every store folds with `DotStatsValues.merge_from` / `DotStatsDef.merge`. The obvious SQL store spells the rule in SQL (`amount + ?`, `GREATEST`, `LEAST`, which SQLite calls `max` and `min`), and that is a fifth copy of the rule in a fourth language, per dialect.

`DotStatsStoreSql` instead reads the player's rows, folds them with `DotStatsDef.merge`, and writes the result **guarded by a `revision` column**: an UPDATE names the revision it read, and one that finds no row lost a race with another server and re-reads, up to `max_attempts`. A first value is a plain INSERT, never an upsert, so a row another server made in between is a duplicate key and a re-read rather than an overwrite. The suite's `RacingDriver` fails both checks with the guard removed, and the live scene has two stores write one player at once against each database and requires exact totals.

## A partial failure names what did not land

`error.context["unapplied"]` lists the stats that did not land, because the store writes stat by stat and the tracker re-queues: re-queuing the whole delta after half of it landed adds those counters twice. The tracker's pending set is the store's half of the reporter's queue, with the same two properties: a failed write keeps what it had, and is put back *under* anything checkpointed since, so a gauge ends at its newest reading.

## Ordering comes from the kind

`top()` and `rank_of()` rank a `LOWEST` ascending and everything else descending, and a tie shares a rank (1, 2, 2, 4). A ranking of an undeclared stat is refused, not empty: it has no direction, and guessing one renders "fewest deaths" upside down.

## dot-sql, duck-typed

The store reaches dot-sql **duck-typed**, so the addon names no dot-sql class and parses without it; dot-sql is linked into `addons/` (gitignored) only for the suites. The table is `DotStatsSqlSchema`'s spec (`SqlSchema`, because `DotStatsSchema` is already the set of definitions).
