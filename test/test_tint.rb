# frozen_string_literal: true

require "test_helper"
require "differential"
require "tempfile"

# `tint` — moving the whole picture toward a color, which is `fade`'s sibling and not a
# fade with a color argument. A fade changes BRIGHTNESS (a display can do that to a
# finished picture); a tint mixes a color IN. They reach the screen by different means
# and round differently, so the numbers below are asserted rather than derived.
class TestTint < Minitest::Test
  include Differential

  # A green screen and one tint, as the DSL writes it.
  def tinted(color, amount, screen_kind: :bitmap, tear_free: false)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen screen_kind, tear_free: tear_free
      clear_screen :green
      tint color, amount
      halt
    end
    b.emit_pending_functions
    b.program
  end

  def shown(program)
    Reference.new.run(program).screen.pixel(120, 80)
  end

  GREEN = 0x03E0
  RED = 0x001F

  # --- what a tint looks like ---

  def test_no_amount_leaves_the_picture_as_drawn
    assert_equal GREEN, shown(tinted(:red, 0))
  end

  def test_a_full_tint_leaves_nothing_but_the_color
    assert_equal RED, shown(tinted(:red, 100))
  end

  # Half way is NOT "half of each channel rounded once". The display takes each side's
  # share separately and truncates each before adding, which is why this is 0x01ef and
  # not something a simpler formula would give.
  def test_half_way_mixes_the_two_a_channel_at_a_time
    assert_equal 0x01EF, shown(tinted(:red, 50))
  end

  def test_the_amount_walks_the_picture_toward_the_color
    seen = [0, 25, 50, 75, 100].map { |amount| shown(tinted(:red, amount)) }

    assert_equal [GREEN, 0x02E7, 0x01EF, 0x00F7, RED], seen
  end

  # The picture is not redrawn, so it is all still there when the tint lifts. Written as
  # two tints in one program, because that is how a game brings one back.
  def test_the_picture_comes_back_untouched
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.emit_pending_functions

    assert_equal GREEN, shown(b.program)
  end

  # A tint the game works out, rather than one written into the program — the form an
  # effect walked over frames needs.
  def test_an_amount_the_game_works_out
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      level.set 50
      tint :red, level
      halt
    end
    b.emit_pending_functions

    assert_equal 0x01EF, shown(b.program)
  end

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

  # The whole screen, not the five pixels above. `blended:` allows the emulator its
  # coarser blend (see Differential::EMULATOR_BLEND_SLACK); the exact arithmetic is what
  # the per-color assertions above pin.
  def test_the_console_agrees_over_the_whole_screen
    assert_backends_agree(tinted(:red, 50), frames: 2, blended: true)
  end

  # A tint the game works out is converted as the program runs, which is a different
  # path through the lowering than a number written into it.
  def test_the_console_agrees_on_an_amount_the_game_works_out
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop do
        level.set 50
        tint :red, level
      end
    end
    b.emit_pending_functions
    program = b.program

    oracle = Reference.new.run(program, frames: 2).screen.pixel(120, 80)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTV"), frames: 6).pixel_gba(120, 80)

    assert_equal 0x01EF, oracle
    assert_equal oracle, console
  end

  # --- a tint and a fade are one effect on the display ---
  #
  # There is one blend on the console and both verbs drive it, so the last one set is
  # the one in force. Modelled rather than hidden: a program cannot look right on one
  # backend and wrong on the other.

  def test_a_tint_after_a_fade_replaces_it
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      fade :black, 100
      tint :red, 100
      halt
    end
    b.emit_pending_functions

    assert_equal RED, shown(b.program)
  end

  def test_a_fade_after_a_tint_replaces_it
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      fade :black, 100
      halt
    end
    b.emit_pending_functions

    assert_equal 0x0000, shown(b.program)
  end

  # --- the screens that draw through a color table ---
  #
  # The tear-free bitmap screen and the tiled screen don't hold a color in every pixel:
  # a pixel is a number that picks a color out of a shared table. The display's own
  # blend cannot tint them (the color it would blend against is the table's own first
  # entry — see Backends::GBA::PaletteTint), so the framework moves the table instead.
  # The author writes the same `tint`; these pin that the picture comes out the same.

  # A green screen and one tint on the tear-free screen. Its colors are drawn from a
  # table, so this exercises the other mechanism entirely.
  def buffered_tint(color, amount)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :green
        tint color, amount
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_the_tear_free_screen_walks_the_picture_toward_the_color
    seen = [0, 25, 50, 75, 100].map { |amount| shown(buffered_tint(:red, amount)) }

    assert_equal [GREEN, 0x02E7, 0x01EF, 0x00F7, RED], seen
  end

  def test_the_console_tints_the_tear_free_screen_the_same
    [0, 50, 100].each do |amount|
      program = buffered_tint(:red, amount)
      console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTB"), frames: 6).pixel_gba(120, 80)

      assert_equal shown(program), console, "at #{amount}% the two backends disagree"
    end
  end

  # A tiled screen: one solid background under one sprite, in different colors. The
  # scenery and the sprite draw from two different tables and BOTH have to move, which
  # is the thing the table mechanism buys over every other way of doing this.
  SOLID_TILE = ("#" * 8 + "\n") * 8

  def tiled_tint(amount, extra_frames: 0)
    tile = SOLID_TILE
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :tiled
      image(:ground, "#" => :green) { tile }
      image(:body, "#" => :white) { tile }
      tiles :grass, "#" => :ground
      background :field, tiles: :grass, map: Array.new(20) { "#" * 30 }
      sprite :body, at: [64, 64]
      level = var :level, 0
      game_loop do
        level.set amount
        tint :red, level
      end
    end
    b.emit_pending_functions
    b.program
  end

  # (64, 64) is the sprite's top-left corner; (8, 8) is scenery well clear of it.
  SPRITE_XY = [66, 66].freeze
  SCENERY_XY = [8, 8].freeze

  WHITE = 0x7FFF

  # The green scenery and the white sprite, each at 0%, 50% and 100% of the way to red.
  # Named here rather than derived so a lowering that quietly changed the arithmetic on
  # one screen could not move both sides of the comparison below with it.
  TILED_SCENERY = [GREEN, 0x01EF, RED].freeze
  TILED_SPRITE = [WHITE, 0x3DFF, RED].freeze
  TILED_AMOUNTS = [0, 50, 100].freeze

  def test_a_tiled_screen_tints_the_scenery_and_the_sprites_together
    seen = TILED_AMOUNTS.map do |amount|
      screen = Reference.new.run(tiled_tint(amount), frames: 2).screen
      [screen.pixel(*SCENERY_XY), screen.pixel(*SPRITE_XY)]
    end

    assert_equal TILED_SCENERY, seen.map(&:first)
    assert_equal TILED_SPRITE, seen.map(&:last)
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
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      level = var :level, 100
      game_loop do
        clear_screen :green
        tint :red, level
        level.set 0
      end
    end
    b.emit_pending_functions
    program = b.program

    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTU"), frames: 8)

    assert_equal GREEN, console.pixel_gba(120, 80)
  end

  # An amount the game works out takes the other path through the lowering — the steps
  # are worked out as the program runs, and so is the color's share of every entry.
  def test_the_console_agrees_on_a_worked_out_amount_on_the_tear_free_screen
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      level = var :level, 0
      game_loop do
        clear_screen :green
        level.set 50
        tint :red, level
      end
    end
    b.emit_pending_functions
    program = b.program

    oracle = Reference.new.run(program, frames: 2).screen.pixel(120, 80)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTW"), frames: 6).pixel_gba(120, 80)

    assert_equal 0x01EF, oracle
    assert_equal oracle, console
  end

  # On this screen the fade and the tint are separate pieces of hardware, so nothing
  # puts a tint away by itself. The display still shows one whole-picture effect at a
  # time — the rule the DSL states — so the fade has to put the colors back, and the
  # console must land where the interpreter says.
  def test_a_fade_after_a_tint_replaces_it_on_the_tear_free_screen
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :green
        tint :red, 100
        fade :white, 0
      end
    end
    b.emit_pending_functions
    program = b.program

    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTF"), frames: 8)

    assert_equal GREEN, shown(program)
    assert_equal GREEN, console.pixel_gba(120, 80)
  end

  # A game whose scenes cross the two display systems puts a DIFFERENT color table in the
  # same place on each switch, so a tint remembered from before the crossing describes a
  # table that is no longer there. Here a tear-free scene tints itself fully red, hands
  # over to a tiled scene, and comes back with the tint lifted — and the picture has to be
  # the green it was drawn as, not the red left in a table nobody put back.
  def crossing_program
    tile = SOLID_TILE
    b = RubyGBA::Builder.new
    b.instance_eval do
      image(:dot, "#" => :white) { tile }
      screen :bitmap, tear_free: true
      state = var :state, 0
      level = var :level, 100
      frames = var :frames, 0
      scene :field do
        clear_screen :green
        tint :red, level
      end
      scene :away do
        screen :tiled
        sprite :dot, at: [200, 140]
      end
      game_loop do
        frames.add 1
        state.set 0
        (frames > 2).then { state.set 1 }
        (frames > 5).then { state.set 0; level.set 0 }
        case_var :state do
          when_val 0, :field
          when_val 1, :away
        end
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_tint_does_not_survive_a_trip_through_the_other_display
    program = crossing_program
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TINTX"), frames: 14)

    assert_equal GREEN, Reference.new.run(program, frames: 10).screen.pixel(120, 80)
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

  def tint_cost_program(moving:, tinting: true)
    colors = TINT_COST_COLORS
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      level = var :level, 100
      colors.times { |i| pixel i, 0, i + 1 } # one pixel per color, painted once at boot
      game_loop do
        # The same two statements either way, so the loop itself cancels. One walks the
        # level to 0 and back on alternate frames; the other puts it straight back.
        level.flip
        moving ? level.add(100) : level.flip
        tint :red, level if tinting
      end
    end
    b.emit_pending_functions
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

  # How many of a frame's scanlines the CPU was busy for, read off the console.
  def frame_scanlines(program, name)
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

  # --- what it refuses, and why ---

  def test_an_amount_out_of_range_says_the_range
    error = assert_raises(ArgumentError) { tinted(:red, 140) }

    assert_includes error.message, "0 to 100"
  end

  def test_an_unknown_color_is_refused
    assert_raises(ArgumentError) { tinted(:reddish, 50) }
  end

  # --- the guardrail ---

  def warnings(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_full_tint_never_lifted_is_a_warning
    assert_includes warnings(tinted(:red, 100)), :tint_never_lifted
  end

  def test_a_tint_that_is_lifted_says_nothing
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_partial_tint_is_a_style_choice_not_a_bug
    refute_includes warnings(tinted(:red, 60)), :tint_never_lifted
  end

  # A tint over time is written with a variable, and where it ends up is not knowable
  # while building — so those programs are left alone rather than warned at.
  def test_a_tint_the_game_works_out_is_left_alone
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop { level.approach 100, 4; tint :red, level }
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_program_with_no_tint_says_nothing
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      halt
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
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
  def cost_of(&body)
    rom = RubyGBA.build("TINT", code: "TINT", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop { body.call(self) }
    end
    RubyGBA::Profiler.run(rom, frames: 20, picture: false).samples_per_frame
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

  def draw_a_lot(builder)
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

