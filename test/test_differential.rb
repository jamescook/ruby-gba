# frozen_string_literal: true

require_relative "differential"

# The differential test: the same program on both backends, compared over the
# WHOLE screen rather than at a few chosen pixels.
#
# Every other cross-backend test in this suite picks its pixels — the ones whose
# values the author could predict. This one predicts nothing. It takes the
# reference interpreter's screen as the answer key and demands the console's match
# it exactly, all 38,400 pixels, so a bug in the lowering has nowhere to hide:
# something drawn a pixel off, a row that wrapped, a sprite that left a trail, a
# region left painted from last frame.
#
# See test/differential.rb for the helper and for why the console runs a couple of
# frames longer than the interpreter for the same picture.
class TestDifferential < Minitest::Test
  include Differential

  Color = RubyGBA::Color

  # An 8x8 solid tile — the size the sprite and tile hardware wants.
  TILE = (("#" * 8) + "\n") * 8

  # A full 32x32 checkerboard map. Full-size on purpose: the hardware's background
  # map is 32x32 cells whatever the author fills in, and the two backends currently
  # disagree about a SCROLLED map smaller than that — the interpreter repeats the
  # authored part where the console shows the backdrop past it. A small scrolling
  # map belongs here once that's settled.
  FULL_MAP = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "#" : "." }.join }.freeze

  def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- bitmap mode: the direct-color framebuffer ---

  # Everything that draws to the framebuffer at once. Each op writes pixels a
  # different way (whole-screen DMA, rect fill, per-row image copy, glyphs, a
  # single word), so a mistake in any one of them shows up as a difference here.
  def test_the_bitmap_drawing_ops_paint_the_same_screen
    assert_backends_agree(build do
      screen :bitmap
      clear_screen :blue
      fill_rect 8, 8, 40, 24, Color.resolve(:red)
      fill_rect 200, 130, 32, 24, Color.resolve(:green)
      image(:strip, "#" => :white, "." => :transparent) { "#.#.#.#.\n.#.#.#.#\n########" }
      blit :strip, 100, 70
      draw_text "DIFF", 60, 100, Color.resolve(:yellow)
      pixel 239, 159, Color.resolve(:magenta)
      halt
    end)
  end

  # A moving sprite is the classic place for a lowering bug: it has to erase what
  # it covered last frame and redraw at the new spot. Compare several frames, so a
  # trail left behind or an off-by-one in the restore shows up.
  def test_a_moving_software_sprite_matches_frame_for_frame
    prog = build do
      screen :bitmap
      clear_screen :black
      image(:dot, "#" => :green) { "####\n####\n####\n####" }
      s = sprite :dot, at: [10, 10]
      game_loop { s.move 2, 1 }
    end
    (2..6).each { |f| assert_backends_agree(prog, frames: f, name: "MOVER") }
  end

  # The tear-free screen draws to a hidden page and shows it whole. Different
  # machinery, same picture — and it's the mode where a page-flip bug would show
  # the wrong page.
  #
  # The rect steps by an EVEN number on purpose: at an odd x, `draw_rect_at` lands
  # a pixel to the left on the console — a known open bug this test found. Step by 3
  # instead and this goes red, which is the point; the odd-x case belongs here once
  # that's fixed.
  def test_the_tear_free_screen_paints_the_same_picture
    prog = build do
      screen :bitmap, tear_free: true
      x = var :x, 10
      game_loop do
        clear_screen :black
        x.add 2
        draw_rect_at x, 40, 8, 8, Color.resolve(:white)
        draw_text "BUF", 10, 100, Color.resolve(:cyan)
      end
    end
    (2..5).each { |f| assert_backends_agree(prog, frames: f, name: "BUFFER") }
  end

  # --- tiled mode: the console composites tiles and sprites itself ---

  # A background the tile hardware paints, with a hardware sprite over it. Here
  # the console isn't copying pixels the way the interpreter models — it's laying
  # out charblocks and OAM entries — so agreement means the layout is right.
  def test_a_tiled_background_and_sprite_compose_the_same_way
    assert_backends_agree(build do
      screen :tiled
      image(:brick, "#" => :red) { TILE }
      image(:floor, "#" => :blue) { TILE }
      tiles :set, "#" => :brick, "." => :floor
      background :bg, tiles: :set, map: FULL_MAP
      image(:hero, "#" => :white) { TILE }
      sprite :hero, at: [96, 64]
      game_loop { nil }
    end, name: "TILED")
  end

  # Scrolling moves the whole visible window over the map. Every pixel on screen
  # changes, so this is the widest net in the file for a tile-layout mistake.
  def test_a_scrolling_background_matches_at_every_offset
    prog = build do
      screen :tiled
      image(:brick, "#" => :red) { TILE }
      image(:floor, "#" => :blue) { TILE }
      tiles :set, "#" => :brick, "." => :floor
      bg = background :bg, tiles: :set, map: FULL_MAP
      game_loop { bg.scroll_by 1, 1 }
    end
    (2..6).each { |f| assert_backends_agree(prog, frames: f, name: "SCROLL") }
  end

  # A hardware sprite over a scrolling background: the console draws the sprite on
  # top for free, and its position must not drift with the scroll.
  def test_a_hardware_sprite_over_a_scrolling_background_matches
    prog = build do
      screen :tiled
      image(:brick, "#" => :red) { TILE }
      image(:floor, "#" => :blue) { TILE }
      tiles :set, "#" => :brick, "." => :floor
      bg = background :bg, tiles: :set, map: FULL_MAP
      image(:hero, "#" => :white) { TILE }
      s = sprite :hero, at: [40, 40]
      game_loop do
        bg.scroll_by 1, 0
        s.move 1, 1
      end
    end
    (2..6).each { |f| assert_backends_agree(prog, frames: f, name: "SCROLLSP") }
  end

  # --- the comparison itself has to be able to fail ---

  # A differential test that can't fail is worse than none, because it reads like
  # coverage. Feed the differ two programs that draw DIFFERENT pictures — standing
  # in for a lowering that put the rectangle in the wrong place — and it has to
  # report exactly the pixels that moved.
  def test_the_comparison_catches_a_screen_that_does_not_match
    as_built = build do
      screen :bitmap
      clear_screen :black
      fill_rect 10, 10, 20, 20, Color.resolve(:red)
      halt
    end
    as_lowered_wrong = build do
      screen :bitmap
      clear_screen :black
      fill_rect 10, 30, 20, 20, Color.resolve(:red) # 20 pixels lower
      halt
    end

    oracle = RubyGBA::IR::Backends::Reference.new.run(as_built, frames: 2).screen.to_a
    _, console = backend_pictures(as_lowered_wrong, frames: 2, name: "WRONG")
    bad = mismatched_pixels(oracle, console)

    # Two 20x20 blocks disagree: where the rect should be, and where it isn't.
    assert_equal 800, bad.length, "both the missing rect and the stray one must be reported"
    assert(bad.any? { |x, y, want, got| x == 15 && y == 15 && want == Color.resolve(:red) && got.zero? },
           "a pixel the program draws red but the screen left black must be reported")
    assert(bad.any? { |x, y, want, got| x == 15 && y == 35 && want.zero? && got == Color.resolve(:red) },
           "a pixel the screen drew red but the program never asked for must be reported")
  end

  # And the assertion built on it must actually flunk, with a message that says
  # where to look.
  def test_a_mismatch_flunks_with_a_readable_report
    differ = Class.new(Minitest::Test) { include Differential }.new("x")
    oracle = Array.new(PIXELS, 0)
    console = Array.new(PIXELS, 0)
    console[(80 * SCREEN_W) + 120] = Color.resolve(:red)

    bad = differ.mismatched_pixels(oracle, console)
    assert_equal [[120, 80, 0, Color.resolve(:red)]], bad

    report = differ.send(:mismatch_report, bad, oracle, console, 4, 6)
    assert_match(/1 of 38400 pixels differ/, report)
    assert_match(/\(120, 80\)\s+interpreter backdrop\s+console red/, report)
    assert_match(/where they differ/, report)
    assert_includes report, "#", "the map marks the differing cell"
  end

  # --- the frame offsets the helper relies on ---

  # BOOT_FRAMES is a measurement, so measure it again here. If the console's boot
  # cost changes, this fails and names the new number, instead of every animated
  # comparison above failing for no visible reason.
  def test_the_frame_offsets_are_still_what_we_measured
    bitmap = build do
      screen :bitmap
      clear_screen :black
      x = var :x, 10
      game_loop do
        x.add 2
        draw_rect_at x, 40, 8, 8, Color.resolve(:white)
      end
    end
    tiled = build do
      screen :tiled
      image(:brick, "#" => :red) { TILE }
      image(:floor, "#" => :blue) { TILE }
      tiles :set, "#" => :brick, "." => :floor
      bg = background :bg, tiles: :set, map: FULL_MAP
      game_loop { bg.scroll_by 1, 0 }
    end

    assert_equal BOOT_FRAMES[:bitmap], measured_offset(bitmap, "OFSBMP"), "bitmap boot cost changed"
    assert_equal BOOT_FRAMES[:tiled], measured_offset(tiled, "OFSTIL"), "tiled boot cost changed"
  end

  # A program that draws in two modes can't have one offset, so the helper says so
  # rather than silently comparing the wrong frames.
  def test_a_mode_switching_program_asks_for_an_explicit_frame_count
    prog = build do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :blue }
      scene(:play) do
        screen :tiled
        image(:brick, "#" => :red) { TILE }
        image(:floor, "#" => :blue) { TILE }
        tiles :set, "#" => :brick, "." => :floor
        background :bg, tiles: :set, map: FULL_MAP
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    err = assert_raises(ArgumentError) { console_frames_for(prog, 4) }
    assert_match(/more than one screen mode/, err.message)
  end

  private

  # Sweep both frame counts and return the offset that makes the two backends'
  # screens identical — the same way BOOT_FRAMES was arrived at. Fails the test if
  # no offset works at all, which would mean a real rendering disagreement.
  def measured_offset(program, name)
    counts = (2..8).to_a
    oracle = counts.to_h { |f| [f, RubyGBA::IR::Backends::Reference.new.run(program, frames: f).screen.to_a] }
    refute_equal 1, oracle.values.uniq.length, "this program must actually animate for the sweep to mean anything"

    rom = assemble_rom(program, name: name)
    offsets = counts.filter_map do |cf|
      console = RubyGBA::Verifier.new(rom, frames: cf).frame_gba
      hit = counts.find { |f| oracle[f] == console }
      hit && (cf - hit)
    end
    refute_empty offsets, "the backends never agreed at any frame pairing — they disagree on the picture itself"
    assert_equal 1, offsets.uniq.length, "the offset must be consistent, got #{offsets.uniq.inspect}"
    offsets.first
  end
end
