# frozen_string_literal: true

require "test_helper"

require "differential"

# How test/differential.rb lines the console up against the interpreter: the frames the
# console spends before its first pass, the passes of the game loop it managed, and the
# pictures that cannot be lined up at all. All of it is about the cartridge run in the
# emulator, so it is the GBA lowering's; on a native run the same helper hands back the game
# as C's picture, and none of this applies. test_differential.rb holds what is true of both.
class TestConsoleLineUp < Minitest::Test
  include Differential

  # A full 32x32 checkerboard map — the whole grid the console gives a background.
  FULL_MAP = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "#" : "." }.join }.freeze

  private def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
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
        x.add! 2
        draw_rect_at x, 40, 8, 8, Color.resolve(:white)
      end
    end
    tiled = build do
      screen :tiled
      image(:brick, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :set, "#" => :brick, "." => :floor
      bg = background :bg, tiles: :set, map: FULL_MAP
      game_loop { bg.scroll_by 1, 0 }
    end

    turning = build do
      screen :rotozoom
      image(:brick, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :set, "#" => :brick, "." => :floor
      bg = background :bg, tiles: :set, map: FULL_MAP # square, which a turning map must be
      game_loop { bg.rotate bg.angle + 5 }
    end

    assert_equal BOOT_FRAMES[:bitmap], measured_offset(bitmap, "OFSBMP"), "bitmap boot cost changed"
    assert_equal BOOT_FRAMES[:tiled], measured_offset(tiled, "OFSTIL"), "tiled boot cost changed"
    assert_equal BOOT_FRAMES[:rotozoom], measured_offset(turning, "OFSROT"), "turning boot cost changed"
  end

  # --- a game that does not fit in a frame ---

  # A pass that takes two frames plays half as much game per frame on the console, so
  # "the same picture" is no longer the same frame count. Lined up on the passes the
  # console managed, an over-budget tear-free game still compares — and a held button is
  # held for the passes on both sides, not for the frames.
  private def over_budget(tear_free:)
    build do
      screen :bitmap, tear_free: tear_free
      x = var :x, 10
      game_loop do
        held(:right).then { x.add! 3 }
        repeat(12) { clear_screen :black } # far more than a frame's worth of drawing
        draw_rect_at x, 40, 8, 8, Color.resolve(:white)
      end
    end
  end

  def test_an_over_budget_tear_free_game_is_lined_up_on_the_passes_it_managed
    _oracle, _console, ran = backend_pictures(over_budget(tear_free: true), frames: 6, name: "SLOW", keys: [:right])

    assert_operator ran, :<, 6, "the console managed fewer passes than frames, and the interpreter played that many"
    assert_backends_agree(over_budget(tear_free: true), frames: 6, name: "SLOW", keys: [:right])
  end

  # A single-buffered picture caught mid-pass is half drawn, and no interpreter frame can
  # match it — so the helper says that is what happened, rather than comparing two
  # different moments and blaming the lowering.
  def test_an_over_budget_single_buffered_game_is_refused_with_the_reason
    err = assert_raises(Minitest::Assertion) do
      assert_backends_agree(over_budget(tear_free: false), frames: 6, name: "TORN", keys: [:right])
    end
    assert_match(/too slow for its frame/, err.message)
    assert_match(/went round the game loop \d+ times/, err.message)
  end

  # --- a game that takes longer to boot than the offset ---

  # BOOT_FRAMES was measured on a program with almost nothing to set up. A real tiled game
  # has a map to upload and a cast to declare, and that spills into a second frame — so the
  # console reaches its loop late and is one pass behind for the whole run, however fast the
  # game itself is. A still picture cannot show it; this one moves, so it can.
  #
  # A pool of sprites over a background is what found it. What tips it over is the pool's
  # CAPACITY, not how many are live and not what the body computes: the same program with a
  # capacity of 16 boots inside the offset and this one does not.
  private def slow_to_boot
    build do
      screen :tiled
      image(:brick, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      image(:guy, "#" => :white) { SOLID_TILE }
      tiles :set, "#" => :brick, "." => :floor
      background :bg, tiles: :set, map: FULL_MAP
      guards = pool :guard, x: 0, y: 0, capacity: 32, image: :guy
      6.times { |i| guards.spawn(x: (i * 20) + 16, y: 32) }
      game_loop { guards.each { |g| g.x.add! 2 } }
    end
  end

  def test_a_game_that_boots_late_is_lined_up_on_the_passes_it_managed
    _oracle, _console, ran = backend_pictures(slow_to_boot, frames: 6, name: "BOOT")

    assert_operator ran, :<, 6, "the console reached its loop late, and the interpreter played the passes it managed"
  end

  # ...and then it draws the same picture WHILE STILL MOVING, which is the thing a fixed
  # offset could not do. Every frame is compared, so a rule that happened to suit one of
  # them cannot pass.
  def test_a_game_that_boots_late_still_matches_frame_for_frame
    program = slow_to_boot
    (1..8).each { |f| assert_backends_agree(program, frames: f, name: "BOOT") }
  end

  # A tiled screen composes its picture from the sprite table and the scroll registers,
  # which the framework writes in one go right after the vblank — so there is no such thing
  # as catching it half-drawn, and its passes can be counted on. A single-buffered bitmap
  # screen is the one that cannot (see the refusal above).
  def test_a_tiled_screen_can_be_lined_up_on_passes_and_a_plain_bitmap_one_cannot
    assert shows_finished_passes?(slow_to_boot)
    assert shows_finished_passes?(over_budget(tear_free: true))
    refute shows_finished_passes?(over_budget(tear_free: false))
  end

  # A program that names no screen at all draws on a plain bitmap one, and both halves of
  # the helper have to say so — the frame offset it gets and whether its passes can be
  # counted on. They are worked out separately, so this pins them together.
  def test_a_program_that_names_no_screen_is_a_plain_bitmap_one_to_both_halves
    silent = build { game_loop { var(:x, 0).add! 1 } }

    refute shows_finished_passes?(silent)
    assert_equal BOOT_FRAMES[:bitmap], console_frames_for(silent, 4) - 4
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
        image(:brick, "#" => :red) { SOLID_TILE }
        image(:floor, "#" => :blue) { SOLID_TILE }
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
    assert_match(/more than one kind of screen/, err.message)
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
      console = RubyGBA::Diagnostics::Verifier.new(rom, frames: cf).frame_gba
      hit = counts.find { |f| oracle[f] == console }
      hit && (cf - hit)
    end
    refute_empty offsets, "the backends never agreed at any frame pairing — they disagree on the picture itself"
    assert_equal 1, offsets.uniq.length, "the offset must be consistent, got #{offsets.uniq.inspect}"
    offsets.first
  end
end
