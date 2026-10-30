# Running the suite

```bash
rake test:all                                                   # the suite, on every lowering
rake test TEST=test/all/vblank/dsl/test_thing.rb                    # one file, on each lowering that plays it
rake test TEST=test/all/vblank/dsl/test_thing.rb TESTOPTS="--name=/pattern/"  # one test; -n /pat/ trips shell quoting
rake test:lowering:gba                                          # the GBA lowering's run alone (TEST= too)
rake test:lowering:native                                       # the native lowering's run alone (TEST= too)
rake test:lowering:js                                           # the JavaScript lowering's run alone (TEST= too)
rake test:lowering:ruby                                         # the Ruby lowering's run alone (TEST= too)
rake test:lowering:gbc                                          # the Game Boy Color lowering's run alone (TEST= too)
rake test:playthroughs                                          # every test in test/lowering/gba/vblank/playthroughs/
bundle exec ruby -Itest test/all/vblank/dsl/test_thing.rb           # one file, plain minitest (needs bundle exec)
```

| what changed | what to run |
|---|---|
| the native lowering's C runtime | `rake test:lowering:native` |
| the JavaScript lowering's own code: its printer, its runtime | `rake test:lowering:js` |
| the Ruby lowering's own code: its printer, its runtime | `rake test:lowering:ruby` |
| the native lowering's statements (`Native::Lowering`, `Picture`, `Sound`, `Saving`), which the JavaScript and Ruby lowerings print too | `rake test:lowering:native`, `rake test:lowering:js` and `rake test:lowering:ruby` |
| the GBA lowering's own code: the ARM it emits | `rake test:lowering:gba` |
| the Game Boy Color lowering's own code: the SM83 it emits, its runtime, its art | `rake test:lowering:gbc` |
| anything every lowering reads: the DSL, the IR, the interpreter, the build checks, the test helpers | `rake test:all` |

Every run checks its output against the interpreter, so a change inside one lowering can break
only that run. The interpreter is the answer key for all of them, so a change to it is never
narrow. Measured on 2026-10-18, a whole `rake test:all` took about fifteen minutes: 177 seconds for
the GBA run, 531 for the native and 199 for the JavaScript.

## One whole run on the machine at a time

`rake test:all`, and each lowering's run alone, take one machine-wide lock (`tools/suite_lock.rb`,
the file `~/.cache/vblank/test-suites.lock`) before starting — `rake test:all` once for all its
runs — so a second run waits and says which run, in which checkout, it waits for. A `TEST=` run
does not take it.

Two checkouts (a worktree per piece of work, or two sessions) wait on each other's whole runs by
default. `VBLANK_SUITE_LOCK=checkout` takes a lock of the checkout's own instead, so it goes
ahead beside a run elsewhere; the two share the cores and each takes about twice as long. Two
runs in one checkout still wait. Set it in the environment of a session working in a worktree.
The lowerings' runs inside `rake test:all` go one after the other, each with all the cores.

## The native run uses processes, not Ractors

A Ractor cannot start the child processes a native test needs, so
`lib/vblank/testing/processes.rb` starts `TEST_PROCESSES` processes (as many as the GBA run has
workers unless told) and hands them one test at a time, so one slow file never decides how long
a run takes. Each sends its results back and the run prints one report — the same totals,
failures and skips by reason a single process would. A process that dies under a test costs that
test, reported as an error saying how it died, and a new one takes its place. Not threads: a
native test is nearly all Ruby work, and threads take turns at that. The native run never checks
for shared state; the GBA run plays the same file and does.

## YJIT is on where it makes a run faster

Measured, YJIT made the native and JavaScript runs faster, the Game Boy Color's slower, and the
GBA run, in Ractors, many times slower. Each run's record says whether it gets YJIT
(`Testing::Lowering::Run#yjit`), a run in Ractors never does, and `Testing::TestTask#yjit?` says
how; a `--yjit` in RUBYOPT does not turn it back on where it is off. Re-measure after a change
to Ruby or to what a run spends its time on.

## Standard output is unbuffered, so a test in a Ractor can start a program

`vblank/testing` sets `$stdout.sync`; the comment beside it says why. Taken out, a test in a
Ractor that starts a program (ImageMagick, for a game whose art is read from a file) stops as a
deadlock now and then, as the Pac-Man example's tests did.
