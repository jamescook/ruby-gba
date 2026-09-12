# frozen_string_literal: true

require "test_helper"

# Differential testing: run the SAME program on both backends and compare the
# WHOLE screen, pixel for pixel.
#
# The individual feature tests check a handful of pixels each — the ones whoever
# wrote the test thought to look at. That leaves the rest of the screen unwatched,
# so a lowering bug that draws in the wrong place, or leaves something behind, or
# paints past an edge, can sit there green. This compares all 38,400 pixels, so
# the only way to pass is to draw the same picture the reference interpreter does.
#
# The interpreter is the oracle: it says what the program MEANS. Any disagreement
# is a bug in the ROM the GBA backend built (or, occasionally, in the
# interpreter's model of the hardware — either way it's a real disagreement worth
# a look).
module Differential

  SCREEN_W = 240
  SCREEN_H = 160
  PIXELS = SCREEN_W * SCREEN_H

  # How many frames the console spends getting to the game loop's first pass,
  # before the interpreter's frame 1 has an equivalent. The two backends both
  # count frames, but they don't start counting at the same moment: the console
  # powers on, runs the ROM's setup and reaches the loop, while the interpreter
  # starts at the first statement. So "the same picture" means the console run is
  # a couple of frames longer.
  #
  # These are measured, not derived — sweep both frame counts on an animated
  # program and see which pairing makes the frames identical. Two programs in each
  # mode agree on the number, and #test_the_frame_offsets_are_still_what_we_measured
  # in test_differential.rb re-measures it so a change in boot cost shows up as a
  # failure here instead of as mysterious drift in every differential test.
  BOOT_FRAMES = {
    bitmap: 2, # same buffered (`tear_free: true`) or not
    tiled: 1,
  }.freeze

  # Run +program+ on both backends and assert they draw exactly the same screen.
  #
  # +frames+ is how many frames the INTERPRETER plays; the console is run for the
  # matching number (see BOOT_FRAMES). For a program that halts or sits still the
  # count barely matters; for an animated one it selects which frame is compared.
  # +blended+ says the picture has a display effect on it — a fade or a tint. Those need
  # a little slack, for a reason that is about the EMULATOR rather than the program.
  #
  # The console blends in the five bits a channel actually has. The emulator is built for
  # 32-bit color, so it widens each channel to eight bits and blends there — and it
  # divides the RED channel on its raw byte while dividing green and blue on their
  # shifted fields, which are 256 times finer. The three channels therefore truncate
  # differently, which is why a uniform gray comes back from a fade with unequal
  # channels. It is a quirk of that renderer and says nothing about our lowering.
  #
  # The bound is PROVED, not sampled: test_emulator_blend.rb walks every 5-bit value
  # against every amount, for both fade directions and the tint, and asserts the emulator
  # never reads low and never more than this far high — and that this number is tight, so
  # it cannot quietly cover more than it was measured to.
  #
  # KEEPING IT ONE-SIDED IS THE POINT. The bug this was written alongside — the
  # interpreter fading toward black by taking a truncated share away rather than keeping
  # one — made the INTERPRETER read high, which is the side with no slack at all. A plain
  # absolute difference would have hidden it. Do not "tidy" this into one.
  #
  # So this still proves an effect reached the right pixels. What it cannot prove is the
  # last step of the arithmetic; that is what the exact per-color assertions against
  # measured console values are for.
  EMULATOR_BLEND_SLACK = 1

  # A FRAME MEANS TWO DIFFERENT THINGS ONCE A GAME IS OVER BUDGET. The interpreter runs the
  # game loop once per frame it is asked for, whatever the body costs. The console runs it
  # once per frame it has TIME for. So a game whose pass takes two display frames plays half
  # as much game per frame on the console, and the boot offset above stops being the whole
  # story: measured on the wolf3d view, holding a button for 40 frames walked the player
  # 2.8 cells in the interpreter and 1.47 on the console.
  #
  # So the two are lined up on PASSES of the loop, not on frames. A hidden counter is added
  # to the program the console runs (the interpreter runs the original), the console is run
  # for its frames, the counter says how many passes it managed, and the interpreter is run
  # for exactly that many. No ratio, no measurement, no cost model, and it stays right when
  # the game gets faster or slower. For a game that fits the counter agrees with the boot
  # offset and nothing changes.
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
  PASSES = :__diff_passes

  # A button name as the console's key bit, for holding buttons on both backends.
  KEY_BITS = RubyGBA::IR::Buttons::NAMES.to_h do |name|
    [name, RubyGBA::Constants.const_get(:"KEY_#{name.to_s.upcase}")]
  end.freeze

  class OverBudget < StandardError; end

  # +keys+ are buttons held for the whole run, on both backends.
  def assert_backends_agree(program, frames: 4, name: "DIFF", console_frames: nil, blended: false, keys: [])
    oracle, console, ran = backend_pictures(program, frames: frames, name: name,
                                            console_frames: console_frames, keys: keys)
    bad = mismatched_pixels(oracle, console, slack: blended ? EMULATOR_BLEND_SLACK : 0)
    return if bad.empty?

    flunk mismatch_report(bad, oracle, console, ran, console_frames || console_frames_for(program, frames))
  rescue OverBudget => e
    flunk e.message
  end

  # Both backends' screens for the same program, as arrays of 15-bit colors
  # (index = y*240 + x), and how many frames the interpreter played to match. Use this
  # directly to assert on a KNOWN disagreement — a bug that's filed but not fixed —
  # instead of failing the build.
  # @return [Array(Array<Integer>, Array<Integer>, Integer)] the interpreter's, the
  #   console's, the interpreter's frame count
  def backend_pictures(program, frames: 4, name: "DIFF", console_frames: nil, keys: [])
    cf = console_frames || console_frames_for(program, frames)
    console, passes = console_picture(program, cf, name, keys)
    ran = passes ? oracle_frames_for(program, frames, passes, cf) : frames
    # What the interpreter SHOWS, not what it stored. A fade, a tint and the camera all
    # change the picture without touching a drawn pixel, so reading the stored cells
    # would compare a picture nobody is looking at against one the console really put out.
    oracle = RubyGBA::IR::Backends::Reference.new.hold(*keys).run(program, frames: ran).screen.shown
    [oracle, console, ran]
  end

  # The console's picture after +cf+ frames, and how many passes of the game loop it
  # managed in them — nil for a program with no loop to count.
  def console_picture(program, cf, name, keys)
    mask = keys.sum { |key| KEY_BITS.fetch(key) }
    counted = RubyGBA::Analyzer.instrument_frame_counter(program, PASSES)
    return [RubyGBA::Verifier.new(assemble_rom(program, name: name), frames: cf, keys: mask).frame_gba, nil] unless counted

    backend = RubyGBA::IR::Backends::GBA.new
    rom = RubyGBA::ROM.assemble(backend.lower(counted), title: name, code: "TEST", maker: "01")
    verifier = RubyGBA::Verifier.new(rom, frames: cf, keys: mask, vars: backend.var_addresses)
    [verifier.frame_gba, verifier.var(PASSES)]
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
  # THE TWO ARE LINED UP ON PASSES (see PASSES), and a boot offset that puts the console a
  # pass behind is the same thing as a slow game: whether the console spent a frame
  # uploading tiles or a frame drawing, it has one pass fewer to show. So a program whose
  # picture is a FINISHED pass is compared at the passes it finished, and the boot offset is
  # only there to give it enough frames to make them. This is what BOOT_SLACK below cannot
  # do: it forgives a missing pass, which is right for a still picture and a frame of drift
  # for a moving one.
  #
  # A console that boots inside the offset has finished at least as many passes as were
  # asked for, and then the number asked for is the one to play — the surplus is slack in
  # the offset rather than a moment the caller wanted.
  def oracle_frames_for(program, frames, passes, cf)
    return passes if passes < frames && shows_finished_passes?(program)
    return frames if passes >= frames - BOOT_SLACK

    raise OverBudget,
          "the console managed only #{passes} passes of the game loop in #{cf} frames, where a game that " \
          "fits manages at least #{frames - BOOT_SLACK}: this program is over budget, and its single-buffered " \
          "picture is caught in the middle of a pass, which no interpreter frame can match. Compare it " \
          "tear-free (screen :bitmap, tear_free: true), or compare a still picture."
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

  # Every pixel the two disagree on, as [x, y, interpreter_color, console_color].
  # +slack+ is how many steps the emulator is allowed to read HIGH in a channel; 0 means
  # the colors have to be identical (see EMULATOR_BLEND_SLACK).
  def mismatched_pixels(oracle, console, slack: 0)
    (0...PIXELS).filter_map do |i|
      next if oracle[i] == console[i]
      next if slack.positive? && within_slack?(oracle[i], console[i], slack)

      [i % SCREEN_W, i / SCREEN_W, oracle[i], console[i]]
    end
  end

  # Is every channel of the emulator's color the interpreter's, or up to +slack+ above it?
  # Never below — reading low is a real disagreement, whatever the slack.
  def within_slack?(want, got, slack)
    3.times.all? do |channel|
      shift = channel * 5
      (0..slack).cover?(((got >> shift) & 0x1F) - ((want >> shift) & 0x1F))
    end
  end

  # How many frames to run the console so its picture lines up with the
  # interpreter's after +frames+. A program that switches display mode mid-run
  # (a bitmap title handing off to a tiled game) has no single answer, so it has
  # to say which it wants.
  def console_frames_for(program, frames)
    modes = program.walk.select { |n| n.kind == :screen }.map { |n| n.mode }.uniq
    if modes.length > 1
      raise ArgumentError,
            "this program uses more than one screen mode (#{modes.inspect}), so the frame offset " \
            "is ambiguous — pass console_frames: explicitly"
    end
    frames + BOOT_FRAMES.fetch(modes.first || :bitmap)
  end

  private

  # A failure that says WHERE they disagree, not just how many pixels. The map is
  # the whole screen squashed to a small grid, so a glance says "the sprite is in
  # the wrong place" vs "the right edge is torn" vs "everything below the map".
  def mismatch_report(bad, _oracle, _console, frames, console_frames)
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

  # A readable name for a 15-bit color, falling back to the raw value. 0 is the
  # backdrop — what shows where nothing was drawn.
  def color_label(value)
    return "backdrop" if value.zero?

    name = RubyGBA::Color::PRESETS.key(value)
    name ? name.to_s : format("0x%04X", value)
  end
end
