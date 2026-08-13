# frozen_string_literal: true

require "test_helper"

# The auto-managed palette pass. The double-buffered display is 8-bit *indexed*:
# every pixel is a small number that picks a color out of a 256-entry table, not
# the color itself. The framework promises the game author never has to know that —
# they keep writing color NAMES. This pass is what makes that promise keepable: it
# walks the finished program, gathers every distinct color it actually uses, and
# hands each one a table slot. A human can check the numbers below by eye against
# the named-color values in Color::PRESETS.
class TestIRPalette < Minitest::Test
  Palette = RubyGBA::IR::Palette
  Build = RubyGBA::IR::Build

  # Build a program through the DSL, the way a game author would.
  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Slot 0 is always black, whether or not the program mentions black. An unpainted
  # (all-zero) framebuffer then reads as black for free — the same "empty screen is
  # black" the direct-color mode gives you.
  def test_slot_zero_is_always_black
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :white
    end)

    assert_equal 0, pal.index_of(:black)
    assert_equal 0x0000, pal.color_at(0)
  end

  # Distinct named colors get slots 1, 2, 3... in the order the program first uses
  # them (black already holds 0). The values are the plain BGR555 presets.
  def test_named_colors_get_stable_first_seen_slots
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :red      # first color seen -> slot 1
      fill_rect 0, 0, 8, 8, :green   # -> slot 2
      pixel 10, 10, :blue    # -> slot 3
    end)

    assert_equal 4, pal.size # black + red + green + blue
    assert_equal 1, pal.index_of(:red)
    assert_equal 2, pal.index_of(:green)
    assert_equal 3, pal.index_of(:blue)

    # entries[i] is the raw 15-bit color at slot i — this is what gets uploaded.
    assert_equal [0x0000, 0x001F, 0x03E0, 0x7C00], pal.entries
  end

  # The same color written three different ways (a name, its raw value, a hex
  # string that downsamples to it) is one color, so it gets one slot.
  def test_colors_are_deduped_by_resolved_value
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :green      # 0x03E0
      fill_rect 0, 0, 8, 8, 0x03E0     # same value, raw
      pixel 5, 5, "#00F800"    # 248>>3 = 31 green -> 0x03E0 too
    end)

    assert_equal 2, pal.size # just black + green
    assert_equal 1, pal.index_of(:green)
  end

  # Using black explicitly doesn't create a second black slot.
  def test_explicit_black_reuses_slot_zero
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :black
      pixel 0, 0, :white
    end)

    assert_equal 2, pal.size # black(0) + white(1)
    assert_equal 0, pal.index_of(:black)
    assert_equal 1, pal.index_of(:white)
  end

  # A bitmap's own pixels count too — blitting it must be able to show its colors,
  # so they need slots. Its transparent pixels are "don't draw", not a color, so
  # they're left out.
  def test_bitmap_pixel_colors_are_collected
    pal = Palette.build(program do
      screen :bitmap
      # "." is transparent, so only red and blue need slots.
      image :ship, "." => :transparent, "#" => :red, "*" => :blue do
        <<~ART
          .#.
          #*#
        ART
      end
      blit :ship, 0, 0
    end)

    assert_equal 3, pal.size # black + red + blue (transparent excluded)
    assert_equal 0x001F, pal.color_at(pal.index_of(:red))
    assert_equal 0x7C00, pal.color_at(pal.index_of(:blue))
  end

  # color_at round-trips: the value at a color's slot is exactly that color.
  def test_index_and_color_round_trip
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :yellow
    end)

    assert_equal 0x03FF, pal.color_at(pal.index_of(:yellow))
  end

  # More than 256 distinct colors can't fit the table. That's a friendly build-time
  # error naming the count, not a silent black screen.
  def test_too_many_colors_is_a_friendly_error
    # 256 distinct non-black colors (raw values 1..256) plus the reserved black
    # needs 257 slots — one past the limit.
    prog = Build.program(
      Build.screen(:bitmap),
      *(1..256).map { |c| Build.pixel(0, 0, c) },
    )

    err = assert_raises(Palette::Overflow) { Palette.build(prog) }
    assert_match(/256/, err.message)
    # Points the author at the direct-color escape hatch, in plain language.
    assert_match(/screen :bitmap/, err.message)
    refute_match(/DISPCNT|VRAM|palette RAM/, err.message, "no hardware jargon in the message")
  end

  # Exactly 256 colors including the reserved black is fine (255 named + black).
  def test_exactly_256_entries_is_allowed
    prog = Build.program(
      Build.screen(:bitmap),
      *(1..255).map { |c| Build.pixel(0, 0, c) },
    )

    pal = Palette.build(prog)
    assert_equal 256, pal.size
  end

  # Asking for a color the program never uses is a bug in the caller, not a
  # silently-wrong index. (Black is the one always-present exception.)
  def test_index_of_unknown_color_raises
    pal = Palette.build(program do
      screen :bitmap
      clear_screen :red
    end)

    assert_raises(ArgumentError) { pal.index_of(:green) }
  end

  # A screen may be given its colors instead of the framework working them out. That is for art
  # made somewhere else, whose pixels are numbers picking out of the table it was made against —
  # so the ORDER is the whole point and nothing may be moved, dropped or added.
  def test_a_given_table_is_used_in_the_order_it_was_given
    pal = Palette.build(program do
      screen :bitmap, tear_free: true, colors: %i[white red black blue]
      clear_screen :black
      game_loop { fill_rect 0, 0, 8, 8, :red }
    end)

    assert_equal 4, pal.size
    assert_equal Color.resolve(:white), pal.color_at(0)
    assert_equal 1, pal.index_of(:red)
    assert_equal 2, pal.index_of(:black), "black takes its given slot, not the reserved one"
  end

  # The derived path reserves slot 0 for black so an unpainted screen reads as black. A given
  # table decides its own slot 0, because a picture made against it says so.
  def test_a_given_table_does_not_get_black_added_to_it
    pal = Palette.build(program do
      screen :bitmap, tear_free: true, colors: %i[red green]
      game_loop { fill_rect 0, 0, 8, 8, :red }
    end)

    assert_equal 2, pal.size
    refute_includes pal.entries, Color.resolve(:black)
  end

  # A real imported table repeats colors. Dropping a repeat would shift every slot after it and
  # move every pixel of every picture, so both stay and drawing uses the first.
  def test_a_repeated_color_keeps_both_slots_and_draws_with_the_first
    pal = Palette.build(program do
      screen :bitmap, tear_free: true, colors: %i[black red black]
      game_loop { fill_rect 0, 0, 8, 8, :black }
    end)

    assert_equal 3, pal.size
    assert_equal 0, pal.index_of(:black)
  end

  def test_drawing_with_a_color_the_screen_was_not_given_is_refused_by_name
    err = assert_raises(Palette::Missing) do
      Palette.build(program do
        screen :bitmap, tear_free: true, colors: %i[black red]
        game_loop { fill_rect 0, 0, 8, 8, :magenta }
      end)
    end

    assert_match(/magenta/, err.message)
    refute_match(/slot|index|VRAM/, err.message, "no hardware jargon in the message")
  end

  # The display holds one table, so two scenes naming different ones is a contradiction.
  def test_two_screens_given_different_colors_is_refused
    err = assert_raises(Palette::Conflict) do
      Palette.build(program do
        scene(:a) { screen :bitmap, tear_free: true, colors: %i[black red] }
        scene(:b) { screen :bitmap, tear_free: true, colors: %i[black blue green] }
        game_loop { case_var(:state) { when_val 0, :a; when_val 1, :b } }
      end)
    end

    assert_match(/one table/, err.message)
  end

  def test_the_same_colors_given_to_every_screen_is_fine
    pal = Palette.build(program do
      scene(:a) { screen :bitmap, tear_free: true, colors: %i[black red] }
      scene(:b) { screen :bitmap, tear_free: true, colors: %i[black red] }
      game_loop { case_var(:state) { when_val 0, :a; when_val 1, :b } }
    end)

    assert_equal 2, pal.size
  end

  # Given colors are for the indexed screen. A plain bitmap screen holds a whole color in every
  # pixel, so there is no table for them to be.
  def test_colors_without_the_tear_free_screen_is_refused
    err = assert_raises(ArgumentError) do
      program do
        screen :bitmap, colors: %i[black red]
      end
    end

    assert_match(/tear_free/, err.message)
  end

  def test_more_colors_than_the_screen_holds_is_refused
    err = assert_raises(ArgumentError) do
      program do
        screen :bitmap, tear_free: true, colors: Array.new(300) { :red }
      end
    end

    assert_match(/300/, err.message)
  end
end
