# frozen_string_literal: true

module RubyGBA
  module Testing
    # DOES THE CARTRIDGE DRAW WHAT THE GAME MEANS? Run the same program on the interpreter and as a
    # cartridge in the emulator, and compare the WHOLE screen, pixel for pixel.
    #
    #   class TitleTest < Minitest::Test
    #     include RubyGBA::Testing
    #     include RubyGBA::Testing::Pictures
    #
    #     def test_the_title_screen
    #       assert_backends_agree(Title.program, frames: 4)
    #     end
    #   end
    #
    # A test that checks a handful of pixels checks the ones whoever wrote it thought to look at.
    # That leaves the rest of the screen unwatched, so a lowering bug that draws in the wrong
    # place, or leaves something behind, or paints past an edge, can sit there green. This
    # compares all 38,400 pixels, so the only way to pass is to draw the same picture the
    # interpreter does.
    #
    # The interpreter is the answer key: it says what the program MEANS. Any disagreement is a bug
    # in the cartridge the GBA lowering built (or, now and then, in the interpreter's model of the
    # hardware — either way it is a real disagreement worth a look).
    #
    # IT NEEDS THE EMULATOR, the ruby-gba-emulator gem, which a game that only builds cartridges
    # does without; a game's Gemfile names it in its test group. Without it the check stops with
    # what to add to the Gemfile (see Diagnostics::Emulator). On the native lowering's run there is
    # no cartridge, and the same lines ask whether the game as C draws what the interpreter draws.
    module Pictures
      SCREEN_W = 240
      SCREEN_H = 160
      PIXELS = SCREEN_W * SCREEN_H

      # How many frames the console spends getting to the game loop's first pass, before the
      # interpreter's frame 1 has an equivalent. The two backends both count frames, but they
      # don't start counting at the same moment: the console powers on, runs the cartridge's setup
      # and reaches the loop, while the interpreter starts at the first statement. So "the same
      # picture" means the console run is a couple of frames longer.
      #
      # These are measured, not derived — sweep both frame counts on an animated program and see
      # which pairing makes the frames identical. Two programs in each mode agree on the number,
      # and ruby-gba's test_console_line_up.rb re-measures it, so a change in boot cost shows up as
      # a failure there instead of as mysterious drift in every comparison.
      BOOT_FRAMES = {
        bitmap: 2, # same buffered (`tear_free: true`) or not
        tiled: 1,
        rotozoom: 1, # the other tile screen, and it boots the same
      }.freeze

      # A button name as the console's key bit, for holding buttons on both backends.
      KEY_BITS = IR::Buttons::NAMES.to_h do |name|
        [name, Console::Hardware.const_get(:"KEY_#{name.to_s.upcase}")]
      end.freeze

      class OverBudget < StandardError; end

      # Run +program+ on both backends and assert they draw exactly the same screen.
      #
      # +frames+ is how many frames the INTERPRETER plays; the console is run for the matching
      # number (see BOOT_FRAMES). For a program that halts or sits still the count barely matters;
      # for an animated one it selects which frame is compared. Give a list (`frames: [3, 5, 7]`,
      # or `frames: 1..20` for every frame of the first twenty) and each is compared, the first
      # that differs failing the test; each is a run of its own from power-on, so a long list is
      # slow. +keys+ are buttons held for the whole run, on both backends. +name+ is the
      # cartridge's title, which nothing compares.
      #
      # WITHOUT THE EMULATOR the test fails, saying what to add to the Gemfile, rather than
      # stopping with an error from inside the library.
      #
      # Every pixel is held to exactly the same color, display effects included. The emulator is
      # built for 32-bit color, so it widens each channel to eight bits and fades, tints and sees
      # through there, and the interpreter works each of those out the same way.
      #
      # ON A NATIVE RUN THERE IS NO CONSOLE TO ASK, and the question still has an answer worth
      # having there: does the game as C draw what the interpreter draws? So the same line plays the
      # program as C with the same buttons held and compares it with the interpreter on every frame,
      # every variable and the sound log with the picture (see CheckedPlayer, which is what comes
      # back). The frames the console would have needed mean nothing there. A JavaScript run asks
      # the same of the game as JavaScript.
      def assert_backends_agree(program, frames: 4, name: "DIFF", console_frames: nil, keys: [])
        each = frames.is_a?(Integer) ? [frames] : frames.to_a
        if console_frames && each.size > 1
          raise ArgumentError, "console_frames: gives the console's frame count for one frame. " \
                               "This check asks for #{each.size} frames. Give one frame, or leave out console_frames:."
        end
        return Testing.player_class.new.hold(*keys).run(program, frames: each.max) if Testing.checked?

        each.each do |frame|
          oracle, console, ran = backend_pictures(program, frames: frame, name: name,
                                                           console_frames: console_frames, keys: keys)
          bad = mismatched_pixels(oracle, console)
          next if bad.empty?

          flunk mismatch_message(bad, ran, console_frames || console_frames_for(program, frame))
        end
      rescue OverBudget, LoadError => e
        flunk e.message
      end

      # Both backends' screens for the same program, as arrays of 15-bit colors (index =
      # y*240 + x), and how many frames the interpreter played to match. Use this directly to
      # assert on a KNOWN disagreement — a bug that's filed but not fixed — instead of failing
      # the build.
      # @return [Array(Array<Integer>, Array<Integer>, Integer)] the interpreter's, the
      #   console's, the interpreter's frame count
      #
      # ON A NATIVE RUN the second picture is the game as C's, after the same frames with the same
      # buttons held, so every test written as "the two pictures agree" asks it of the lowering the
      # run is for. The C is checked against the interpreter on every frame on the way there
      # (CheckedPlayer), and the frames the console would have needed mean nothing. On a JavaScript
      # run it is the game as JavaScript's, the same way.
      def backend_pictures(program, frames: 4, name: "DIFF", console_frames: nil, keys: [])
        return lowered_pictures(program, frames, keys) if Testing.checked?

        played = console_frames || console_frames_for(program, frames)
        console, passes = console_picture(program, played, name, keys)
        ran = passes ? oracle_frames_for(program, frames, passes, played) : frames
        # What the interpreter SHOWS, not what it stored. A fade, a tint and the camera all
        # change the picture without touching a drawn pixel, so reading the stored cells
        # would compare a picture nobody is looking at against one the console really put out.
        oracle = IR::Backends::Reference.new.hold(*keys).run(program, frames: ran).screen.shown
        [oracle, console, ran]
      end

      # Every pixel the two pictures disagree on, as [x, y, interpreter_color, console_color].
      # A picture is as wide as the screen of the console it was drawn for, the one whose
      # screen has as many pixels as it does.
      def mismatched_pixels(oracle, console)
        width = Console::DESCRIPTIONS.values.find { |d| d.screen_width * d.screen_height == oracle.length }&.screen_width
        width ||= SCREEN_W
        (0...[oracle.length, console.length].max).filter_map do |i|
          next if oracle[i] == console[i]

          [i % width, i / width, oracle[i], console[i]]
        end
      end

      private

      # The console's picture after +console_frames+ frames, and how many passes of the game loop it
      # managed in them — nil for a program with no loop to count.
      #
      # A FRAME MEANS TWO DIFFERENT THINGS ONCE A GAME IS OVER BUDGET. The interpreter runs the
      # game loop once per frame it is asked for, whatever the body costs. The console runs it
      # once per frame it has TIME for. So a game whose pass takes two display frames plays half
      # as much game per frame on the console, and the boot offset stops being the whole story:
      # measured on a first-person view, holding a button for 40 frames walked the player nearly
      # twice as far in the interpreter as on the console.
      #
      # So the two are lined up on PASSES of the loop, not on frames. The console is run for its
      # frames while the emulator counts how many times the game loop was entered, and the
      # interpreter is then run for exactly that many passes. No ratio, no measurement, no cost
      # model, and it stays right when the game gets faster or slower. For a game that fits, the
      # count agrees with the boot offset and nothing changes.
      #
      # THE SAME COUNT ANSWERS A SECOND QUESTION, which is where it earns its keep. BOOT_FRAMES
      # is one number per screen mode, measured on a program with almost nothing to set up. A
      # real game has a map to upload and a cast to declare, reaches its loop a frame later, and
      # is then one pass behind for the whole run however fast the game itself is. To the picture
      # that is the same thing as being slow — a pass fewer to show — and the pass count already
      # says so, whichever of the two it was.
      #
      # A game whose picture cannot be caught half-drawn can be lined up this way (see
      # #shows_finished_passes?). A single-buffered bitmap game caught mid-pass has a half-drawn
      # picture that no interpreter frame can match — so that one is refused, with the reason,
      # rather than compared at two different moments and the lowering blamed.
      #
      # THE CONSOLE RUNS THE SAME BYTES THE INTERPRETER IS GIVEN. Counting passes by adding a
      # variable and an instruction to the game loop would mean the cartridge every pixel was
      # proved identical about was not the cartridge that ships — and one extra instruction can
      # tip a routine out of the console's quick memory, which changes the timing and therefore
      # changes what is being compared. The emulator counts arrivals at the loop's own first
      # instruction instead, so nothing is added to the program.
      #
      # A comparison with the console is a check of the cartridge, so a native or JavaScript run
      # never asks for one: #backend_pictures hands it the lowered game's picture instead.
      def console_picture(program, console_frames, name, keys)
        Diagnostics::Emulator.load!
        mask = keys.sum { |key| KEY_BITS.fetch(key) }
        backend = IR::Backends::GBA.new
        rom = Cartridge::ROM.assemble(backend.lower(program), title: name, code: "TEST", maker: "01",
                                                             built: backend.build_record(program))
        verifier = Diagnostics::Verifier.new(rom, frames: console_frames, keys: mask, count_passes: true)
        [verifier.frame_gba, verifier.passes]
      end

      # The interpreter's picture and the game as C's (or as JavaScript's) after +frames+ frames,
      # with +keys+ held.
      # The interpreter plays the program as the lowered game's player does: on the Game Boy
      # Color's run, as a Color program, on its screen.
      def lowered_pictures(program, frames, keys)
        native = Testing.player_class.new.hold(*keys).run(program, frames: frames).screen.shown
        player = Testing.player_class
        played = player.respond_to?(:program_played) ? player.program_played(program) : program
        oracle = IR::Backends::Reference.new.hold(*keys).run(played, frames: frames).screen.shown
        [oracle, native, frames]
      end

      # A game whose picture cannot be lined up on passes is allowed to be this many passes
      # short of the frame count. The boot offset was measured on a program with almost nothing
      # to set up; one with tiles to upload or hot code to copy reaches its loop a frame later,
      # and a still picture cannot show it. A game over budget by a whole frame a pass falls
      # further behind than this within a few frames, so a test that wants the strict check
      # runs more of them.
      BOOT_SLACK = 1

      # How many frames the interpreter plays so its picture is the one the console showed.
      #
      # THE TWO ARE LINED UP ON PASSES (see #console_picture), and a boot offset that puts the
      # console a pass behind is the same thing as a slow game: whether the console spent a frame
      # uploading tiles or a frame drawing, it has one pass fewer to show. So a program whose
      # picture is a FINISHED pass is compared at the passes it finished, and the boot offset is
      # only there to give it enough frames to make them. This is what BOOT_SLACK cannot do: it
      # forgives a missing pass, which is right for a still picture and a frame of drift for a
      # moving one.
      #
      # A console that boots inside the offset has finished at least as many passes as were
      # asked for, and then the number asked for is the one to play — the surplus is slack in
      # the offset rather than a moment the caller wanted.
      #
      # A SINGLE-BUFFERED CONSOLE PAST THE FRAME COUNT is compared at the passes it finished. Run
      # for the bitmap boot offset, every single-buffered program tried finished a pass MORE than
      # was asked for — the offset gives that screen a frame of room to spare — and on a screen the
      # game paints straight into, the picture is the last pass painted, since a game that keeps
      # up stops in the wait between two passes. Played at the frame count instead, the
      # interpreter shows the pass before, and anything that changes every pass — a pose, a
      # position — reads as a frame of drift that is not in either backend. A screen that shows
      # finished passes (tear-free, tiled) shows the one before the last painted, and is left to
      # the frame count as it always was. BELOW the frame count a single-buffered program keeps
      # BOOT_SLACK's tolerance on purpose: a pass short there is either a late boot or a game over
      # budget caught mid-pass, and the count cannot tell the two apart.
      def oracle_frames_for(program, frames, passes, console_frames)
        return passes if passes > frames && !shows_finished_passes?(program)
        return passes if passes < frames && shows_finished_passes?(program)
        return frames if passes >= frames - BOOT_SLACK

        raise OverBudget,
              "The console went round the game loop #{passes} times in #{console_frames} frames. A game that " \
              "keeps up goes round at least #{frames - BOOT_SLACK} times. So this game is too slow for its " \
              "frame. Its screen keeps one picture, and the console was stopped in the middle of drawing it. " \
              "No frame of the interpreter matches a half-drawn picture. To compare it, use " \
              "screen :bitmap, tear_free: true, or compare a picture that does not change."
      end

      # Is the picture this program shows the state of a pass the console FINISHED, rather than
      # one it is in the middle of?
      #
      # A tiled screen has no framebuffer the game paints into. The game moves variables, and
      # the framework writes the sprite table and the scroll registers in one go right after
      # the vblank, so whatever the display is composing, it is composing from one pass's
      # numbers. A tear-free bitmap screen reaches the same place by the other road: it keeps
      # two pictures and shows the one that is finished. Only a single-buffered bitmap screen
      # can be caught half-drawn — the game paints straight into the picture the display is
      # reading — and that is the one this is false for.
      def shows_finished_passes?(program)
        screens = program.walk.select { |node| node.kind == :screen }
        screens.any? && screens.all? do |screen|
          screen.mode == :bitmap ? screen.buffered : %i[tiled rotozoom].include?(screen.mode)
        end
      end

      # How many frames to run the console so its picture lines up with the interpreter's after
      # +frames+. A program that switches display mode mid-run (a bitmap title handing off to a
      # tiled game) has no single answer, so it has to say which it wants.
      def console_frames_for(program, frames)
        modes = program.walk.select { |n| n.kind == :screen }.map { |n| n.mode }.uniq
        if modes.length > 1
          raise ArgumentError,
                "This program uses more than one kind of screen (#{modes.inspect}). Each kind takes a " \
                "different number of frames to start, so the check cannot work out how long to run the " \
                "console. Give the console's frame count with console_frames:."
        end
        frames + BOOT_FRAMES.fetch(modes.first || :bitmap)
      end

      # A failure that says WHERE they disagree, not just how many pixels. The map is the whole
      # screen squashed to a small grid, so a glance says "the sprite is in the wrong place" vs
      # "the right edge is torn" vs "everything below the map".
      def mismatch_message(bad, frames, console_frames)
        lines = ["the backends drew different screens: #{bad.length} of #{PIXELS} pixels differ " \
                 "(interpreter ran #{frames} frames, console #{console_frames})"]
        lines << "  first differences (interpreter is the oracle — it says what the program means):"
        bad.first(8).each do |x, y, want, got|
          lines << format("    (%3d,%3d)  interpreter %-10s  console %s", x, y, color_label(want), color_label(got))
        end
        lines << "  ...and #{bad.length - 8} more" if bad.length > 8
        lines << "  where they differ ( . = agree, # = differ; each cell is #{SCREEN_W / 40}x#{SCREEN_H / 20} pixels):"
        lines.concat(difference_map(bad))
        lines.join("\n")
      end

      # The screen boiled down to a 40x20 grid: a cell is '#' if any pixel in it differs.
      def difference_map(bad)
        cell_w = SCREEN_W / 40
        cell_h = SCREEN_H / 20
        grid = Array.new(20) { Array.new(40, ".") }
        bad.each { |x, y, _, _| grid[y / cell_h][x / cell_w] = "#" }
        grid.map { |row| "    #{row.join}" }
      end

      # A readable name for a 15-bit color, falling back to the raw value. 0 is the backdrop —
      # what shows where nothing was drawn.
      def color_label(value)
        return "backdrop" if value.zero?

        name = Graphics::Color::PRESETS.key(value)
        name ? name.to_s : format("0x%04X", value)
      end
    end
  end
end
