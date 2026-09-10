# frozen_string_literal: true

module RubyGBA
  # WHAT THE BUILD MADE OF YOUR PROGRAM — read off the finished build, never modelled.
  #
  # Every number here is a fact the build already knows exactly: how big each routine came
  # out, which ones fit in the console's quick memory and which missed, how many of a font's
  # glyphs a game actually draws. Nothing is predicted, so nothing here can drift.
  #
  # WHY THIS IS NOT THE PROFILER'S JOB, and cannot be. A profile runs the finished cartridge
  # and watches where the console was; by then these facts are gone. Nothing in a running ROM
  # can say that a routine missed the quick memory by four tenths of a kilobyte, or that a
  # helper was emitted sixty-four times, or that a font ships forty-three letters and the game
  # draws thirty. Those are decisions the build made, and the build is the only witness.
  #
  # WHAT IS DELIBERATELY ABSENT is any claim about how long a frame takes. This report used to
  # carry one — a frame priced in scanlines, judged against a budget, with a verdict of fits or
  # tears. It was a second statement of what the hardware costs, kept in step with the backend
  # by hand, and every mispricing was a bug. Time is measured now, by running the game, and
  # {Profiler} prints it directly under this.
  module BuildReport
    # Code in the console's 32K of quick memory runs about this much faster than code fetched
    # from the cartridge. It is a property of the two memories — how wide each one is and how
    # many cycles the cartridge makes the console wait — not an estimate of anybody's program,
    # so it is a constant here rather than something worked out per game.
    QUICK_MEMORY_SPEEDUP = 2.3

    # How many routines that missed the quick memory are worth naming. The list is sorted with
    # the most costly miss first, and a reader acts on one at a time.
    NAMED_MISSES = 3

    # How often a line has to repeat before it is worth pointing at. Below this the routine is
    # simply big, and there is nothing an author would do differently.
    #
    # Several DIFFERENT lines repeating the same number of times is a helper — a plain Ruby
    # method called from a build block is emitted at every call site — and that has a one-word
    # fix. ONE line repeating is a single verb with a large expansion (a live number lays out
    # all ten shapes for every digit place), where the same advice would be wrong.
    REPEATED_ENOUGH = 3

    module_function

    def render(rom, out: $stdout)
      built = rom.built
      printer = IR::Printer.for(out)
      program = built.source_program

      quick_memory_lines(built.placement, program, printer)
      glyph_lines(program, printer)
      tearing_line(program, printer)
    end

    # WHAT THE BUILD KEPT IN THE QUICK MEMORY, with each routine's size beside it — size is the
    # whole of why one routine is on this list and another is not, so it belongs next to them.
    def quick_memory_lines(placement, program, printer)
      return if placement.nil? || (placement.funcs.empty? && placement.passed_over.empty?)

      faster = "code runs ~#{QUICK_MEMORY_SPEEDUP}x faster there"
      if placement.funcs.empty?
        printer.puts "  nothing was kept in quick memory (#{faster}):"
      else
        printer.puts "  kept in quick memory (#{faster}):"
        placement.funcs.each do |name|
          printer.puts "    #{routine_size(placement, name)}#{PlainWords.routine(name)}"
        end
        printer.puts format("    %s of 32K used, %s free",
                            kb(placement.used_bytes), kb(placement.free_bytes))
      end
      printer.puts("    #{chosen_from_line(placement)}")
      passed_over_lines(placement, program, printer)
    end

    # WHICH OF THE TWO ANSWERS PICKED THAT LIST, which an author cannot tell by reading it and
    # which is the difference between a tuned game and an untuned one.
    def chosen_from_line(placement)
      return "chosen from a measurement of a real run" if placement.chosen_from == :measurement

      "chosen from the shape of the program — nothing has been measured. To choose from " \
        "what this game really spends its frames on, build it with `RubyGBA.game`, which measures."
    end

    def routine_size(placement, name)
      bytes = placement.sizes[name]
      bytes ? format("%8s  ", kb(bytes)) : " " * 10
    end

    # ...AND WHAT DID NOT FIT, which is the actionable half. A routine the frame spends real
    # time in that just missed is exactly where a program loses that speed, and nothing in a
    # finished cartridge can say so afterwards.
    def passed_over_lines(placement, program, printer)
      return if placement.passed_over.empty?

      placement.passed_over.first(NAMED_MISSES).each do |over|
        printer.puts format("    (%s did not fit — it needs %s and %s was left when its " \
                            "turn came, so it runs from the cartridge.%s)",
                            PlainWords.routine(over.name), kb(over.bytes), kb(over.room),
                            repeated_note(program, over))
      end
    end

    def repeated_note(program, over)
      body = program.walk.find { |node| node.kind == :func && node.name == over.name }
      return "" unless body

      counts = body.walk.filter_map { |n| n.source&.to_s }.tally
      where, times = counts.max_by { |_, count| count } || []
      return "" if where.nil? || times < REPEATED_ENOUGH

      format(" Its most repeated line is %s, emitted %d times.%s",
             where.split("/").last, times, helper_advice(counts, times))
    end

    # Said only when the evidence is there: a run of DIFFERENT lines each emitted the same
    # number of times, which is what a helper looks like from here.
    def helper_advice(counts, times)
      return "" unless counts.count { |_, n| n == times } > 1

      " Several lines repeat together, which is a helper called from more than one place — " \
        "it is emitted at each of them, where a `func` is emitted once."
    end

    def glyph_lines(program, printer)
      IR::GlyphUsage.footprint(program).each do |f|
        printer.puts "  text: font :#{f.font} draws #{f.drawn} of its #{f.total} glyphs"
      end
    end

    # CAN THIS GAME TEAR — asked of its SHAPE, which is the half that is exact and free.
    #
    # A tear is the display reaching a row before the game finished drawing it, so it needs a
    # game that draws straight into the one picture the display is reading. That is a fact
    # about the screen a game chose, not about how long anything takes: a double-buffered game
    # draws to a hidden page shown all at once and CANNOT tear, however slow it is, and a tiled
    # game has no picture of its own to tear.
    #
    # WHAT IS NOT SAID HERE is whether a game that CAN tear actually does. That was a timing
    # claim — a frame priced in scanlines against the brief safe window — and it was invented
    # arithmetic, of exactly the kind this report no longer makes. It is also the one question
    # a run answers outright: {Tearing} holds what the display showed against what the game had
    # finished drawing and counts the rows that disagree. So the shape is stated here and the
    # answer is measured there.
    def tearing_line(program, printer)
      return unless Tearing.measurable?(program)

      printer.puts "  tearing: this game draws straight into the picture the display is " \
                   "reading, so it can tear. Run it to see whether it does."
    end

    def kb(bytes) = format("%.1fK", bytes / 1024.0)
  end
end
