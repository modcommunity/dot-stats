# History

Bugs worth recognising if they come back.

- **A leave queued rows nothing would send.** With `report_to_backbone` off (the default), `end()` still checkpointed a leaving player's delta into the reporter's queue, which then held rows no flush would ever send, and the "will not be reported why=unpublished" warning fired on the first leave of every such server. `_checkpoint` now clears the delta and returns when reporting is off, and the `tracker` section asserts a leave queues nothing and warns about nothing.
- **Every number was lost at the end of every session** on a server with no backbone, because the totals lived only there. The store ([store](store.md)) is the answer.
- **Two servers writing one player at once** is the race the `revision` guard exists for; with the guard removed, the suite's `RacingDriver` fails, and both real databases lose races in the live scene while keeping exact totals.
