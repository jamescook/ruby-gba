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

      stack_lines(program, printer)
      video_memory_lines(built.video_memory, printer)
      quick_memory_lines(built.placement, program, printer)
      roomy_memory_lines(built.roomy_memory, printer)
      glyph_lines(program, printer)
      column_stretch_lines(built.column_stretches, printer)
      tearing_line(program, printer)
    end

    # WHICH SEE-THROUGH PICTURES SKIP THE ROWS THEY HAVE NOTHING IN, and which walk the lot.
    #
    # A picture drawn as a stretched column normally ships with a list, per column, of where
    # that column holds pixels — so a lamp in a square of ceiling costs its lit rows and not
    # its square. Two ceilings can stop that, and when one does the picture goes back to
    # walking every row of every column it draws. Which of the two happened is a fact the
    # build settled, and a picture can nearly always be made to fit, so the advice comes with
    # it. Said only when one missed: a page listing pictures that are all fine teaches nothing.
    def column_stretch_lines(stretches, printer)
      decided = (stretches || {}).to_h
      held_back = decided.reject { |_name, picture| picture.skips_empty_rows? }
      return if held_back.empty?

      printer.puts "  see-through pictures a stretched column draws:"
      decided.each do |name, picture|
        walks = picture.skips_empty_rows? ? "walks only the rows that hold pixels" : "walks every row"
        printer.puts format("    %9s  :%s — %s", "#{picture.height} rows", name, walks)
      end
      held_back.each { |name, picture| printer.puts "    (#{stretch_advice(name, picture)})" }
    end

    # ...and what to do about the one that missed. Each ceiling has its own answer, and the
    # answer is the point of the line.
    def stretch_advice(name, picture)
      missed = ":#{name} walks every row of every column it draws, and most of them draw nothing. "
      rows = IR::Backends::GBA::RUNS_MAX_ROWS
      case picture.held_back_by
      when :too_tall
        "#{missed}A picture more than #{rows} rows tall cannot ship where its columns hold " \
          "pixels. Make it #{rows} rows or fewer."
      else
        "#{missed}Its columns hold pixels in too many separate places to ship. " \
          "Use fewer columns, or draw it from more than one picture."
      end
    end

    # WHAT EACH DECLARED LAYER TURNED OUT TO HOLD, and how deep the picture goes.
    #
    # A layer is a name an author writes; a LEVEL is what the console actually keeps, and it
    # has only four of them. Several layers landing on one level is the normal, wanted answer
    # rather than a compromise — so this shows the levels, with the layers that share each,
    # and says how many are left.
    #
    # WHAT USED TO BE HERE AND IS NOT is a column of scanlines beside each layer, and the
    # share of a frame they came to. Those were the estimate's. What a layer COSTS is a
    # question about time, and `Profiler` answers it by routine, from a real run.
    def stack_lines(program, printer)
      picture = IR::Stacking.picture(program)
      held_by = picture.stack.to_h { |layer| [layer, picture.in_layer(layer)] }
      return if held_by.each_value.all?(&:empty?)

      levels = IR::Backends::GBA::MAX_LEVELS
      printer.puts "  the stack, back to front (the console keeps #{levels} levels):"
      held_by.each do |layer, held|
        next if held.empty?

        printer.puts "    #{layer_level(picture, held).ljust(9)}:#{layer.to_s.ljust(12)}" \
                     "#{layer_holds(picture, layer)}"
      end
      transparency_line(program, printer)
      used = picture.depths.count
      printer.puts "    #{used} of #{levels} levels used, #{levels - used} free"
    end

    # Which level a layer landed on. Nearly always one — a layer holding two backgrounds is
    # the exception, since scenery is the one thing that has to have a level to itself.
    def layer_level(picture, held)
      at = held.map { |name| picture.depths[name] + 1 }.uniq.sort
      at.length == 1 ? "level #{at.first}" : "levels #{at.first}-#{at.last}"
    end

    # What a layer turned out to hold. Backgrounds are named, because an author named them;
    # sprites are counted, because their names are the framework's own.
    def layer_holds(picture, layer)
      scenery = picture.scenery.select { |node| node.layer == layer }.map { |node| "background :#{node.name}" }
      sprites = picture.objects.count { |node| node.layer == layer }
      scenery.push("#{sprites} sprite#{'s' if sprites > 1}") if sprites.positive?
      scenery.join(", ")
    end

    # A see-through layer is worth saying on its own line, because the display blends as it
    # draws — so seeing through a layer costs the same as drawing it solid. Without the line
    # a reader has no way to tell a stack that blends from one that does not.
    def transparency_line(program, printer)
      node = program.each.find { |n| n.kind == :layers && n.transparent }
      return unless node

      fixed = Value.fixed_number(node.transparency)
      if fixed
        printer.puts "    :#{node.transparent} is #{fixed} see-through — " \
                     "the display blends it as it draws, for nothing"
      else
        # The one arrangement where it is not free — and only half of it: the blending is
        # still the display's, and it is the TELLING that costs.
        printer.puts "    :#{node.transparent} is as see-through as the game works out — " \
                     "the display blends it for nothing"
        printer.puts "      ...and the amount is written to it on every frame"
      end
      return unless program.each.any? { |n| n.kind == :fade }

      # The one thing a reader cannot see anywhere else. A fade uses the same blend unit, so
      # it takes that "for nothing" away for as long as it runs — and the two verbs are
      # usually written nowhere near each other.
      printer.puts "      ...except while a fade runs, which takes the same blend: " \
                   ":#{node.transparent} is solid until it lifts"
    end

    # WHERE THE PICTURES WENT, and what the framework's own choice of storage bought back.
    #
    # The console keeps the pictures it draws in a memory of its own, and it is small and
    # fixed. Running out is a build error, so the number worth having is the room left —
    # before a game grows into it rather than after.
    #
    # The second half is the part nobody could work out by reading their own program. A
    # picture drawn from few enough colours is stored at half the size, decided from the art
    # and never asked for, so how much of that room came from the decision is invisible unless
    # the build says. It is usually most of it.
    def video_memory_lines(video, printer)
      return if video.nil? || !video.any?

      printer.puts "  the pictures the console draws:"
      { "sprites" => video.sprites, "tiles" => video.tiles }.each do |what, area|
        next if area.nil?

        printer.puts format("    %-8s %s of %s used, %s free%s",
                            what, room(area.used), room(area.capacity), room(area.free),
                            storage_note(area))
      end
      object_count_lines(video.objects, printer)
    end

    # HOW MANY OF THE CONSOLE'S SPRITES THE GAME REALLY SPENDS — said only when it is not
    # one per sprite, which is the only time it can surprise anybody. A picture too big for
    # one object is drawn as several standing shoulder to shoulder, and the author wrote
    # one sprite; the same goes for the windows that hold a placed fade off a sprite.
    def object_count_lines(objects, printer)
      return if objects.nil?

      printer.puts "  the sprites the console draws at once: " \
                   "#{objects.used} of #{objects.capacity} used, #{objects.free} free"
      objects.big.each do |name, count|
        printer.puts "    :#{name} is bigger than one sprite, so it is drawn as #{count}"
      end
      return if objects.twins.zero?

      printer.puts "    #{objects.twins} of them hold the placed fade off the sprites in front of it"
    end

    # Picture memory runs from a handful of bytes to tens of kilobytes, and a small sprite
    # rounded to "0.0K" says nothing. Below a kilobyte it is said in bytes.
    def room(bytes) = bytes < 1024 ? "#{bytes} bytes" : kb(bytes)

    # How the pictures in one area were stored, and what that saved. Said as a count of
    # pictures rather than as a bit depth: how many colours a picture uses is a fact about the
    # art, and how the console reads it is not something an author ever writes.
    def storage_note(area)
      parts = []
      unless area.small.zero?
        parts << "#{area.small} of #{area.small + area.big} stored small, saving #{room(area.saved)}"
        parts << "#{area.big} use more colours than a small one holds" unless area.big.zero?
      end
      # Nothing in a tileset says which of its tiles are really the same picture, so this is
      # the one line that says how much of it was repeats.
      parts << "#{area.shared} were the same picture as another and stored once" if area.shared.positive?
      # A gap left to line a layer up with a starting point of its own. Rare, invisible from
      # the program, and the only part of this memory that is spent on nothing.
      parts << "#{room(area.skipped)} skipped so a layer could count from a place of its own" if area.skipped.positive?
      parts.empty? ? "" : " (#{parts.join('; ')})"
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

    # WHAT WENT IN THE OTHER WORK MEMORY, which is a decision nobody wrote down.
    #
    # The console keeps 256K of it — eight times the quick memory, and about six times the
    # wait on a read. Everything a program declares goes in the quick one until it will not
    # fit; then the coldest collections fall into this one. So a game that used to fail to
    # build now builds, and the only way to see which of its collections moved is to be told.
    #
    # Said only when something is there. A game whose state fits in the quick memory, which
    # is nearly every game, reads nothing about a second memory it never met.
    def roomy_memory_lines(roomy, printer)
      return if roomy.nil? || roomy.used.zero?

      printer.puts format("  the roomy memory (a read there waits ~%dx longer): %s of %s used, %s free",
                          ROOMY_MEMORY_SLOWDOWN, kb(roomy.used), kb(roomy.total), kb(roomy.free))
      roomy.collections.each do |name, bytes|
        printer.puts format("    %8s  :%s", kb(bytes), name)
      end
    end

    # How much longer a whole number takes to read from the roomy memory than from the quick
    # one. It is a property of the two memories — how wide each is and how many cycles the
    # slower one makes the processor wait — not an estimate of anybody's program.
    ROOMY_MEMORY_SLOWDOWN = 6

    # WHICH OF THE TWO ANSWERS PICKED THAT LIST, which an author cannot tell by reading it and
    # which is the difference between a tuned game and an untuned one.
    def chosen_from_line(placement)
      return "chosen from a measurement of a real run" if placement.chosen_from == :measurement

      "chosen from the shape of the program — nothing was measured. To choose from what this " \
        "game really spends its frames on, build it with `RubyGBA.game`, which measures."
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

    # THE SAME FACTS AS THE PROSE, as data — for something comparing two builds rather than
    # reading one. Did the routine that just missed the quick memory now fit? That is the
    # question a before-and-after asks, and nothing should have to match a sentence to ask it.
    def as_json(rom)
      video = { video_memory: rom.built.video_memory&.to_h,
                roomy_memory: rom.built.roomy_memory&.to_h }
      placement = rom.built.placement
      return video.merge(quick_memory: nil) if placement.nil?

      video.merge(quick_memory: {
        total_bytes: placement.used_bytes + placement.free_bytes,
        used_bytes: placement.used_bytes,
        free_bytes: placement.free_bytes,
        chosen_from: placement.chosen_from.to_s,
        kept: placement.funcs.map do |name|
          { name: name.to_s, label: PlainWords.routine(name), bytes: placement.sizes[name] }
        end,
        passed_over: placement.passed_over.map do |over|
          { name: over.name.to_s, label: PlainWords.routine(over.name),
            bytes: over.bytes, room: over.room }
        end
      })
    end

    def kb(bytes) = format("%.1fK", bytes / 1024.0)
  end
end
