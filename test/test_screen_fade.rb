# frozen_string_literal: true

require "test_helper"

# The screen fade — `fade_out`, `fade_in` and `flash_screen`, and the level a game can
# read to sequence a scene change.
#
# `fade` on its own sets a level where it is called; this pack walks that level over
# frames. Nothing is redrawn, so what a test looks at is the same drawing showing a
# different colour as the frames pass, and showing its own colour again once the fade
# lifts. The picture underneath never changes, which is exactly what makes a fade cheap
# and also what makes a fade left un-lifted so hard to spot by eye.
class TestScreenFade < Minitest::Test
  WHITE = RubyGBA::Color.resolve(:white)
  RED = RubyGBA::Color.resolve(:red)
  GREEN = RubyGBA::Color.resolve(:green)
  BLUE = RubyGBA::Color.resolve(:blue)
  BLACK = 0

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A red screen that starts a fade on frame 2. Reading one spot every frame gives the
  # whole ramp, which is the only way to see an effect that exists over time.
  def fading_game(&fade)
    program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add 1
        (frame == 2).then { instance_exec(&fade) }
      end
    end
  end

  # What one spot shows on each of the first +frames+ frames.
  def ramp(prog, frames)
    (1..frames).map { |n| Reference.new.run(prog, frames: n).screen.pixel(120, 80) }
  end

  # --- fading out and back in ---

  def test_a_fade_out_darkens_the_picture_until_nothing_shows_through
    seen = ramp(fading_game { fade_out :black, frames: 6 }, 12)

    assert_equal RED, seen.first, "before the fade the picture is as drawn"
    assert_equal BLACK, seen.last, "after it nothing of the picture shows"
    assert_equal seen.uniq, seen.chunk_while { |a, b| a == b }.map(&:first),
                 "and it only ever gets darker — a ramp does not wander"
  end

  def test_the_screen_stays_faded_until_something_brings_it_back
    seen = ramp(fading_game { fade_out :black, frames: 4 }, 40)

    assert_equal BLACK, seen.last, "a fade that arrives holds there rather than drifting back"
  end

  def test_a_bare_fade_in_comes_back_in_the_same_colour_at_the_same_speed
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add 1
        (frame == 2).then { fade_out :white, frames: 6 }
        (frame == 20).then { fade_in } # no colour, no length — back the way it went
      end
    end
    seen = ramp(prog, 40)

    assert_equal WHITE, seen[14], "it faded to white, not the default black"
    assert_equal RED, seen.last, "and a bare fade_in put the picture back exactly as drawn"
  end

  # `frames:` is how long the ramp takes, so asking for twice as long has to take about
  # twice as many frames. Asserted as a RELATIONSHIP rather than an exact count: a fixture
  # that pinned "arrives on frame 9" would break on any change to where the effect runs in
  # a frame without anything being wrong.
  def test_a_longer_fade_takes_proportionally_longer
    short = ramp(fading_game { fade_out :black, frames: 6 }, 60).index(BLACK)
    long = ramp(fading_game { fade_out :black, frames: 12 }, 60).index(BLACK)

    refute_nil short, "the short fade has to arrive at all"
    assert_in_delta 2.0, long.to_f / short, 0.5,
                    "twice the frames is about twice as long to arrive"
  end

  def test_a_duration_in_seconds_is_the_same_as_the_frames_it_works_out_to
    by_frames = ramp(fading_game { fade_out :black, frames: 30 }, 90).index(BLACK)
    by_seconds = ramp(fading_game { fade_out :black, duration: 0.5 }, 90).index(BLACK)

    assert_equal by_frames, by_seconds, "half a second is thirty frames"
  end

  # --- the flash ---

  # The frame a flash exists for is its FIRST one. An effect that spent that frame part of
  # the way to full would read as a soft glow rather than a hit, so the level is applied
  # before it is moved and this is what says so.
  def test_a_flash_is_at_full_on_the_frame_it_is_seen_first
    seen = ramp(fading_game { flash_screen :white, frames: 6 }, 12)
    lit = seen.index { |px| px != RED }

    refute_nil lit, "the flash has to show at all"
    assert_equal WHITE, seen[lit], "and its first visible frame is the brightest one"
    assert_equal RED, seen.last, "then it falls back to the picture, with nothing left behind"
  end

  def test_a_flash_toward_black_is_the_scene_change_cut
    seen = ramp(fading_game { flash_screen :black, frames: 8 }, 20)

    assert_equal BLACK, seen[seen.index { |px| px != RED }], "it cuts to black at once"
    assert_equal RED, seen.last, "then reveals what is drawn underneath"
  end

  # --- reading the level, which is what sequences a scene change ---

  # Fading out leaves the screen dark on purpose, so a game that switches screens has to
  # wait for the fade before it switches, or it swaps them in plain sight. Reading the
  # level is how it waits. Here the "screens" are two colours, and the test's whole claim
  # is that the change is never visible: no frame shows the new colour part-faded.
  def test_a_scene_change_can_wait_for_the_fade_to_arrive
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      scene_id = var :scene_id, 0
      leaving = var :leaving, 0
      game_loop do
        (scene_id == 0).then { clear_screen :red }.else { clear_screen :white }
        frame.add 1
        (frame == 2).then { fade_out :black, frames: 5; leaving.set 1 }
        (leaving == 1).then do
          (fade_level == 100).then { scene_id.set 1; fade_in frames: 5; leaving.set 0 }
        end
      end
    end
    seen = ramp(prog, 30)

    assert_equal RED, seen.first, "it starts on the first screen"
    assert_equal WHITE, seen.last, "and ends on the second"
    assert_includes seen, BLACK, "having gone through black in between"
    # The swap itself is the thing that must never be seen: every frame is the old colour,
    # the new colour, or somewhere on the way to or from black — never a half-lit swap.
    between = seen[(seen.index(BLACK))..seen.rindex(BLACK)]
    assert_equal [BLACK], between.uniq, "the screens are swapped while nobody can see it"
  end

  # --- friendly errors ---

  def test_frames_and_duration_together_is_an_error
    error = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { fade_out :black, frames: 4, duration: 1.0 } }
    end
    assert_match(/frames: or duration:/, error.message)
  end

  def test_a_nonsense_length_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { fade_out :black, frames: 0 } }
    end
    assert_match(/positive whole number of frames/, error.message)
  end

  def test_a_colour_nobody_has_heard_of_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { fade_out :reddish } }
    end
    assert_match(/unknown color/, error.message)
  end

  # --- a colour other than black or white ---
  #
  # Black and white are a BRIGHTNESS change, which is what `fade` is. Red is not — mixing
  # a colour in is a different piece of the display, and that is `tint`. Both take the
  # same amount and leave the picture untouched underneath, so the ramp above them is one
  # ramp; only the verb the branch reaches for changes.

  def test_a_flash_in_a_colour_goes_full_on_the_frame_it_is_seen_first
    seen = ramp(fading_game { flash_screen :green, frames: 6 }, 12)
    lit = seen.index { |px| px != RED }

    refute_nil lit, "the flash has to show at all"
    assert_equal GREEN, seen[lit], "its first visible frame is nothing but the colour"
    assert_equal RED, seen.last, "then it falls back to the picture, with nothing left behind"
  end

  # Each colour a game asks for gets a branch of its own, so two of them in one game do
  # not collapse into whichever was asked for last.
  def test_two_colours_in_one_game_each_get_their_own_flash
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add 1
        (frame == 2).then { flash_screen :green, frames: 4 }
        (frame == 10).then { flash_screen :blue, frames: 4 }
      end
    end
    seen = ramp(prog, 16)

    assert_includes seen, GREEN
    assert_includes seen, BLUE
  end

  # Placing an effect at a depth works by hiding it from what sits in front, and the
  # console can hide only a brightness change that way. Either order of the two asks the
  # same impossible thing of one game, so both are refused.
  def test_a_coloured_fade_under_a_layer_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :world, :ui
        game_loop { flash_screen :green, under: :ui }
      end
    end
    assert_match(/:black or :white/, error.message)
  end

  def test_a_layer_asked_for_after_a_coloured_fade_is_refused_too
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :world, :ui
        game_loop do
          flash_screen :green
          fade_out under: :ui
        end
      end
    end
    assert_match(/:black or :white/, error.message)
  end

  # --- guardrails ---

  def warnings(prog)
    RubyGBA::IR::Guardrails::Validator.new.run(prog, autofix: false).warnings.map(&:check)
  end

  def test_a_fade_out_with_no_fade_in_is_caught
    prog = program { screen :bitmap; game_loop { clear_screen :red; fade_out } }
    findings = warnings(prog)

    assert_includes findings, :faded_out_never_in
  end

  def test_a_fade_out_that_is_brought_back_is_not_flagged
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add 1
        (frame == 2).then { fade_out }
        (frame == 30).then { fade_in }
      end
    end

    refute_includes warnings(prog), :faded_out_never_in
  end

  # A flash brings the picture back by itself, so a game that only flashes has nothing
  # left un-lifted and must not be nagged.
  def test_a_game_that_only_flashes_is_not_flagged
    prog = program { screen :bitmap; game_loop { clear_screen :red; flash_screen } }

    refute_includes warnings(prog), :faded_out_never_in
  end

  def test_a_fade_with_no_game_loop_is_caught
    prog = program { screen :bitmap; clear_screen :red; fade_out; fade_in; halt }

    assert_includes warnings(prog), :fade_needs_game_loop
  end

  def test_a_fade_inside_a_game_loop_is_not_flagged
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop { clear_screen :red; frame.add 1; (frame == 2).then { fade_out }; (frame == 9).then { fade_in } }
    end

    refute_includes warnings(prog), :fade_needs_game_loop
  end

  def test_a_game_that_never_fades_is_not_flagged
    prog = program { screen :bitmap; game_loop { clear_screen :red } }
    findings = warnings(prog)

    refute_includes findings, :fade_needs_game_loop
    refute_includes findings, :faded_out_never_in
  end

  # --- and on the console ---

  # The lowering, confirmed on real hardware: the same drawing, at the same spot, reading
  # one colour part way through a fade and its own colour again once the fade lifts.
  def test_a_fade_darkens_and_lifts_on_the_console
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add 1
        (frame == 2).then { fade_out :black, frames: 4 }
        (frame == 20).then { fade_in frames: 4 }
      end
    end
    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "FADE", code: "BFAD", maker: "01")

    assert assert_gemba_loads_rom(rom, frames: 12).black?(120, 80),
           "the console really does black the picture out"
    assert assert_gemba_loads_rom(rom, frames: 30).red?(120, 80),
           "and really does put it back"
  end

  # A coloured flash on the TEAR-FREE screen, which is where a real game meets this: that
  # screen draws every pixel through a colour table, so the flash goes through the
  # framework's own blend rather than the display's. Breakout is a tear-free game and its
  # damage flash is exactly this.
  def test_a_coloured_flash_shows_and_lifts_on_the_console
    prog = program do
      screen :bitmap, tear_free: true
      frame = var :frame, 0
      game_loop do
        clear_screen :green
        frame.add 1
        (frame == 2).then { flash_screen :red, frames: 6 }
      end
    end
    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "FLASH", code: "BFLS", maker: "01")

    assert assert_gemba_loads_rom(rom, frames: 4).red?(120, 80),
           "the console really does sting the picture red"
    assert assert_gemba_loads_rom(rom, frames: 30).green?(120, 80),
           "and really does leave it as it was drawn"
  end
end
