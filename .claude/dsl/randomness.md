# DSL reference: Randomness

The whole story of these verbs. The one-line index is `.claude/rules/dsl-reference.md`.

- `seed n` / `randomize` — seed the stream. `roll :var, 1..6` — store a random value. `rand(1..6)` — a random `Value`. `chance(25).then { }` — true 25% of the time.
- `random_numbers` — **the stream itself, for a `save_data` record to keep**: `keep hearts, random_numbers`. The random numbers are a hidden number the game keeps churning, so a save that leaves it out and a load that puts everything else back roll different numbers from there on — the guard that was going to miss now hits. Kept, a load puts the stream back where the save found it and play goes on exactly as it would have. It is nothing else: the numbers are still read with `rand`, `roll` and `chance`. A record's `reset` (a new game) leaves it rolling on rather than starting it where power-on does, which would play every new game's rolls the same. Keeping it in two records is a friendly error, like any kept thing.
