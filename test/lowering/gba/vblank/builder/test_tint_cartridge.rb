# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require "all/vblank/builder/test_tint"

# A TINT ON THE ADVANCE'S CARTRIDGE: the colours read off the cartridge in the emulator, and what
# a tint costs a frame there. What a tint looks like on every run is in
# test/all/vblank/builder/test_tint.rb.
class TestTintCartridge < Minitest::Test
  include TintGames

  # --- the console agrees, which is the point of having two backends ---

  def test_the_console_shows_the_same_colors
    [0, 25, 50, 75, 100].each do |amount|
      program = tinted(:red, amount)
      rom = assemble_rom(program, name: "TINT")
      console = assert_emulator_loads_rom(rom, frames: 6).pixel_gba(120, 80)

      assert_equal shown(program), console,
                   "at #{amount}% the two backends disagree"
    end
  end

  # A tint the game works out is converted as the program runs, which is a different
  # path through the lowering than a number written into it.
  def test_the_console_agrees_on_an_amount_the_game_works_out
    console = assert_emulator_loads_rom(assemble_rom(worked_out_tint, name: "TINTV"), frames: 6).pixel_gba(120, 80)

    assert_equal 0x01EF, console
  end

  def test_the_console_tints_the_tear_free_screen_the_same
    [0, 50, 100].each do |amount|
      program = buffered_tint(:red, amount)
      console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTB"), frames: 6).pixel_gba(120, 80)

      assert_equal shown(program), console, "at #{amount}% the two backends disagree"
    end
  end

  def test_the_console_tints_a_tiled_screen_the_same
    TILED_AMOUNTS.each_with_index do |amount, i|
      console = assert_emulator_loads_rom(assemble_rom(tiled_tint(amount), name: "TINTT"), frames: 6)

      assert_equal TILED_SCENERY[i], console.pixel_gba(*SCENERY_XY),
                   "at #{amount}% the scenery disagrees"
      assert_equal TILED_SPRITE[i], console.pixel_gba(*SPRITE_XY),
                   "at #{amount}% the sprite disagrees"
    end
  end

  # A game writes `tint :red, hurt` on every pass of its loop, so the same tint is asked
  # for again and again. It must land in the same place every time — which it does
  # because each rewrite reads the ORIGINAL colors out of the cartridge rather than the
  # ones already on screen. Blending what is already blended is the bug this rules out,
  # and after twenty frames it would be far past halfway.
  def test_the_same_tint_asked_for_every_frame_lands_in_the_same_place
    program = buffered_tint(:red, 50)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTH"), frames: 20)

    assert_equal 0x01EF, console.pixel_gba(120, 80)
  end

  def test_the_console_brings_a_tinted_table_back_untouched
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      level = var :level, 100
      game_loop do
        clear_screen :green
        tint :red, level
        level.set! 0
      end
    end
    b.finalize_program
    program = b.program

    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTU"), frames: 8)

    assert_equal GREEN, console.pixel_gba(120, 80)
  end

  # An amount the game works out takes the other path through the lowering — the steps
  # are worked out as the program runs, and so is the color's share of every entry.
  def test_the_console_agrees_on_a_worked_out_amount_on_the_tear_free_screen
    console = assert_emulator_loads_rom(assemble_rom(worked_out_buffered_tint, name: "TINTW"), frames: 6)

    assert_equal 0x01EF, console.pixel_gba(120, 80)
  end

  # On this screen the fade and the tint are separate pieces of hardware, so nothing
  # puts a tint away by itself. The display still shows one whole-picture effect at a
  # time — the rule the DSL states — so the fade has to put the colors back, and the
  # console must land where the interpreter says.
  def test_a_fade_after_a_tint_replaces_it_on_the_tear_free_screen
    console = assert_emulator_loads_rom(assemble_rom(buffered_tint_then_fade, name: "TINTF"), frames: 8)

    assert_equal GREEN, console.pixel_gba(120, 80)
  end

  # A tint does not survive a trip through the other display (TintGames#crossing_program).
  def test_a_tint_does_not_survive_a_trip_through_the_other_display
    console = assert_emulator_loads_rom(assemble_rom(crossing_program, name: "TINTX"), frames: 14)

    assert_equal GREEN, console.pixel_gba(120, 80)
  end

  # --- and a tint that is not moving costs nothing ---
  #
  # Moving the table is the one part of this that is not free, so a game holding a tint
  # steady — or, far more often, holding it at 0 while nothing has hit the player — must
  # not pay for it every frame. The framework remembers what it last wrote and jumps over
  # the walk when nothing has changed. That is not visible in the picture (a rewrite
  # reads the originals, so it lands in the same place either way), so it is measured:
  # the console is asked how much of each frame the CPU was busy for.

  # Two hundred colors in the table, and a game loop that either holds the tint where it
  # is or moves it every frame. Everything else about the two is identical, including
  # what is drawn — so the difference between them is the walk and nothing else.
  TINT_COST_COLORS = 200

  private def tint_cost_program(moving:, tinting: true, tear_free: true)
    colors = TINT_COST_COLORS
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      level = var :level, 100
      colors.times { |i| pixel i, 0, i + 1 } # one pixel per color, painted once at boot
      game_loop do
        # The same two statements either way, so the loop itself cancels. One walks the
        # level to 0 and back on alternate frames; the other puts it straight back.
        level.flip!
        moving ? level.add!(100) : level.flip!
        tint :red, level if tinting
      end
    end
    b.finalize_program
    b.program
  end

  # A held tint costs about what no tint at all costs — a compare and a branch — where a
  # moving one walks two hundred colors. Half a scanline of the 228 a frame has is well
  # inside what one reading can tell apart, and far under what the walk itself takes.
  HELD_TINT_SLACK = 0.5

  def test_a_tint_that_is_not_moving_costs_about_nothing
    none = frame_scanlines(tint_cost_program(moving: false, tinting: false), "TINTC0")
    held = frame_scanlines(tint_cost_program(moving: false), "TINTC1")

    assert_in_delta none, held, HELD_TINT_SLACK,
                    "a held tint should cost about what no tint costs (#{none} -> #{held})"
  end

  def test_a_tint_that_moves_pays_for_the_colors_it_moves
    held = frame_scanlines(tint_cost_program(moving: false), "TINTC1")
    moving = frame_scanlines(tint_cost_program(moving: true), "TINTC2")

    assert_operator moving / held, :>, 5.0,
                    "expected a held tint to be far cheaper than a moving one, got " \
                    "#{format('%.2fx', moving / held)} (#{held} -> #{moving})"
  end

  # THE PLAIN BITMAP SCREEN IS THE ONE WHERE A TINT IS FREE. It holds a whole colour in every
  # pixel, so there is no table to walk and the display's own blend does the mixing: moving
  # the tint every frame costs what holding it does. The two bitmap screens are one word apart
  # in a program, and the tear-free one above is the dear one.
  def test_a_moving_tint_costs_nothing_more_on_the_plain_bitmap_screen
    held = frame_scanlines(tint_cost_program(moving: false, tear_free: false), "TINTP1")
    moving = frame_scanlines(tint_cost_program(moving: true, tear_free: false), "TINTP2")

    assert_in_delta held, moving, HELD_TINT_SLACK,
                    "a moving tint on the plain bitmap screen should cost what a held one does (#{held} -> #{moving})"
  end

  # How many of a frame's scanlines the CPU was busy for, read off the console.
  private def frame_scanlines(program, name)
    require_emulator!
    rom = assemble_rom(program, name: name)
    Tempfile.create([name, ".gba"]) do |file|
      file.binmode
      rom.write(file.path)
      file.flush
      probe = RubyGBAEmulator.open(file.path)
      reading = 3.times.map { probe.busy_scanlines(settle: 20) }.min
      probe.close
      return reading.to_f
    end
  end

  # --- what it costs ---
  #
  # A tint tells the display what to show and redraws nothing, so its price must not
  # depend on what is on screen — the same promise `fade` makes.

  # HOW MANY INSTRUCTIONS A FRAME REALLY RUNS, measured on the emulator.
  #
  # This claim is about TIME — a tint tells the display what to show and redraws nothing — and
  # it used to be checked against an estimate of the frame, which is the thing this framework
  # stopped shipping. Emitted code cannot stand in for it either: the palette machinery a tint
  # needs is shared, so it lands wherever it is first required and the same tint reads as 172
  # bytes in one program and 52 in another. So it is run and counted.
  private def cost_of(&body)
    rom = VBlank.build("TINT", console: :gba, code: "TINT", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop { body.call(self) }
    end
    VBlank::Diagnostics::Profiler.run(rom, frames: 20, picture: false).samples_per_frame
  end

  # What a tint adds to a frame must not depend on what else that frame draws. Measured as a
  # difference twice over — the same tint added to an empty frame and to a busy one — so a
  # tint that quietly scaled with the drawing would show up here.
  def test_a_tint_costs_the_same_however_much_is_on_screen
    empty = cost_of { |_g| nil }
    empty_tinted = cost_of { |g| g.tint :red, 50 }
    busy = cost_of { |g| draw_a_lot(g) }
    busy_tinted = cost_of { |g| draw_a_lot(g); g.tint :red, 50 }

    assert_operator busy, :>, empty, "the drawing itself must still cost"
    # A real run, so the two differences agree to within a few instructions rather than
    # exactly — what would fail here is a tint that scaled with the drawing at all.
    assert_in_delta empty_tinted - empty, busy_tinted - busy, 0.15 * (busy - empty)
  end

  def test_a_tint_costs_something
    assert_operator cost_of { |g| g.tint :red, 50 }, :>, cost_of { |_g| nil }
  end

  private def draw_a_lot(builder)
    40.times { |i| builder.fill_rect 0, i, 40, 1, :blue }
  end

  # An amount the game works out costs more than one written into the program: the
  # conversion happens as the program runs.
  def test_a_computed_amount_costs_more_than_a_written_one
    written = cost_of { |g| g.tint :red, 50 }
    computed = cost_of { |g| g.tint :red, g.var(:level, 50) }

    assert_operator computed, :>, written
  end
end
