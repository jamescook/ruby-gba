# DSL reference: The date and time

The whole story of these verbs. The one-line index is `.claude/rules/dsl-reference.md`.

- `clock` → a `Clock`: **the date and time, as the clock a cartridge carries keeps them.** The console has no clock of its own: switched off it forgets, and switched on it only knows how long it has run. Some cartridges carry a clock chip with a watch battery of its own, which keeps counting while the console is off, and that is what a game asks — for berries that grow while nobody plays, or something that happens once a day. Its readings are numbers like any variable's, to draw, compare or keep: `now.hour` (0–23), `now.minute`, `now.second`, `now.year` (as written: 2026), `now.month` (1–12), `now.day` (1–31) and `now.weekday` (0 for Sunday to 6 for Saturday, as the chip counts). **Every reading in one pass of the game loop is of the same moment**, so a minute cannot turn over between reading the minute and the second. **Summer time does not move it**: a clock holds the local time it was set to and counts one second a second. There are no time zones: the chip holds whatever local time it was set to.

  **Ask before you show it.** `now.present?` is false when the cartridge has no clock — most emulators give a cartridge none unless they are told to, and so do some flash cartridges — and `now.set?` is false when the clock is there and was never set: its battery went in or ran out, and it has been counting up from 2000-01-01. **Every reading is 0 when either is false**, so a game that forgets to ask shows zeros, which look wrong, rather than a date that looks right and is not:

  ```ruby
  now = clock
  (now.present? & now.set?).then { draw_number now.hour, 40, 60, :white, digits: 2 }
  ```

  **A game that reads the time and never asks either one is warned when it builds**, naming the first line that reads it. A game that reads it where nobody sees it — to seed its random numbers — can leave the warning be.

  **Setting the clock from the game is not here yet**; a game reads the clock only.

  **Where each build reads it.** The cartridge reads its clock chip; the desktop build reads the computer's clock, and the web build the browser's. Until each of those is written, that build answers as a cartridge with no clock: `present?` false and every reading 0.

  **In a test**, the interpreter has no clock unless the test gives it one, the way it is given the buttons held: `game_player.clock_at(Time.new(2026, 10, 22, 21, 7, 5))`, and `clock_at(time, set: false)` for a clock that was never set. The time moves on a sixtieth of a second for every frame the screen shows — sixty frames are a second, however many passes of the game loop those took — so nothing a test checks depends on when the test runs. A run that ends after 60 frames reads a second later than it started. Worked examples: `test/ruby_gba/builder/test_clock.rb`.
