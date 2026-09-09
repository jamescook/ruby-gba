# frozen_string_literal: true

module RubyGBA
  # WHAT A PERSON CALLS THIS.
  #
  # A build talks: a progress line while it works, a guardrail's warning, a build error, and
  # `rom.explain` at the end. Those four come from corners of the framework that never meet,
  # and every one of them has the same small job somewhere in it — take something the machine
  # knows by an internal name and say it in English.
  #
  # Done where it is needed, that job gets done again in each corner, and the answers drift
  # apart. The console's 32K of fast memory is what that looks like: one name for it in the
  # report, a second in a guardrail's error, a third in the progress line — minutes apart, in
  # one build, read by somebody who is trying to work out what the thing IS. A learner cannot
  # tell three names for one thing from three different things.
  #
  # So the English lives here and the corners read it. Two things follow that cannot be had
  # while it is scattered: rewording something is one edit in one place, and a test can fail
  # when a second name for one thing turns up (see test/test_plain_words.rb).
  #
  # WHAT BELONGS HERE is a name for a thing SEVERAL PLACES have to mention — a piece of
  # hardware, a routine nobody wrote, a verb whose node kind is not what the author typed.
  # What does not belong here is the wording of any one message. A guardrail's sentence is
  # written where the guardrail is, next to the code that knows why it fires; only the shared
  # nouns in it come from here.
  module PlainWords
    # THE CONSOLE'S 32K OF FAST MEMORY. Code and data kept there are reached without waiting,
    # where everything in the cartridge is fetched over a narrow connection — the same
    # instructions run about two and a half times faster in one place than the other, which is
    # why the framework brings it up at all. Its hardware name is IWRAM, and a person reading a
    # build has no reason to know that word, so nothing they read says it.
    QUICK_MEMORY = "quick memory"

    # WHAT IT MUST NEVER BE CALLED, so a test can fail when one of these turns up in something a
    # build prints. Comments are exempt and deliberately so — a comment teaches the hardware and
    # may name IWRAM outright; this is about what a PERSON RUNNING A BUILD reads.
    NOT_CALLED = { QUICK_MEMORY => [/\bfast RAM\b/i, /\bquick RAM\b/i, /\bfast memory\b/i,
                                    /\bIWRAM\b/, /\bfast on-chip\b/i] }.freeze

    # THE TWO ROUTINES THE AUTHOR NEVER WROTE. A game loop's body is statements rather than a
    # routine, and nobody types the routine the console jumps into when the display or a timer
    # announces something — but the build treats both as routines, because that is what lets
    # the same choosing and the same report cover them (see Backends::GBA::Placement). So both
    # turn up in a progress line and in `rom.explain`, and both need a name a reader can place.
    #
    # Everything else on those lists is a routine somebody wrote, and its own name is already
    # the best one there is, so it is given back the way they would type it.
    # The last two are not routines either, and nobody chose them: this chip cannot divide, so
    # every division in a program goes through code the build copies in for it. They show up in
    # a measured profile and need a name a reader can act on — a hot one is worth replacing with
    # a table.
    # The symbols are written out rather than reached for, because this file is loaded long
    # before the backend that defines them. A test holds the two lists against each other.
    ROUTINES = { __frame: "the game loop",
                 __interrupt: "the routine that answers the display and the timers",
                 __divide_routine: "dividing",
                 __divide_fix_routine: "dividing numbers that hold a fraction",
                 __mix_routine: "mixing the sound that is playing" }.freeze

    # One routine per font, made by the lowering so that a number worked out as the game runs
    # is DRAWN by a call rather than by the same code emitted again at every place a number
    # appears. Nobody wrote it, so it needs saying in terms of what an author did write —
    # which is `draw_number`.
    DIGIT_ROUTINE = /\A__digit_routine_(?:buffered_)?(?<font>.+)\z/

    def self.routine(name)
      ROUTINES.fetch(name) do
        if (font = DIGIT_ROUTINE.match(name.to_s))
          "drawing a draw_number's digits (:#{font[:font]})"
        else
          "func :#{name}"
        end
      end
    end

    # THE VERB AN AUTHOR TYPED, for the few node kinds whose internal name is not that verb. A
    # message naming the kind back at somebody names something they never wrote: nobody types
    # `draw_digit`, they type `draw_number`, and a `blit_pose` is what a `sprite` became.
    VERBS = { blit_pose: "sprite", draw_digit: "draw_number" }.freeze

    def self.verb(kind) = VERBS.fetch(kind) { kind.to_s }
  end
end
