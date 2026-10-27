# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The window a game is played live in: SDL3, reached through Fiddle. These open it with SDL's
# dummy video driver, which makes windows nobody sees, so they need no screen. A machine without
# SDL3 skips the ones that open a window, saying what to install.
class TestSDL < Minitest::Test
  # SDL's driver is chosen from the process's settings, and Fiddle calls into C from the main
  # Ractor only.
  runs_on_the_main_ractor!

  SDL = VBlank::Live::SDL
  RATE = 48_000
  FRAME_SAMPLES = 804 # a frame's share of a second at RATE, near enough

  def setup
    @drivers_before = ENV.to_h.slice("SDL_VIDEODRIVER", "SDL_AUDIODRIVER")
    ENV["SDL_VIDEODRIVER"] = "dummy"
    ENV["SDL_AUDIODRIVER"] = "dummy"
  end

  def teardown
    %w[SDL_VIDEODRIVER SDL_AUDIODRIVER].each { |name| ENV[name] = @drivers_before[name] }
  end

  # A frame's sound goes to the speaker, with a little silence ahead of it the first time, so the
  # speaker has something to play while the next frame is made.
  def test_the_sound_a_window_is_handed_waits_for_the_speaker
    window = open_window
    window.play_sound(Array.new(FRAME_SAMPLES, 1000), RATE)

    assert_operator window.sound_waiting, :>, FRAME_SAMPLES
  ensure
    window&.close
  end

  # A game far ahead of the speaker — played faster than the console, say — has the sound past a
  # few frames' worth thrown away, rather than heard ever later.
  def test_sound_far_ahead_of_the_speaker_is_not_kept
    window = open_window
    30.times { window.play_sound(Array.new(FRAME_SAMPLES, 1000), RATE) }

    kept = SDL::SOUND_BEHIND_FRAMES + SDL::SOUND_AHEAD_FRAMES
    assert_operator window.sound_waiting, :>, 0, "the speaker was never opened"
    assert_operator window.sound_waiting, :<=, kept * FRAME_SAMPLES
  ensure
    window&.close
  end

  def test_a_window_shows_a_picture_and_holds_no_buttons_until_one_is_pressed
    window = open_window
    window.show(Array.new(240 * 160, 0x001F), 240, 160)

    assert_empty window.held_buttons(1)
    refute window.stop?
  ensure
    window&.close
  end

  # Closing the window, which SDL hears as the last window gone, stops the play once the window
  # has read what it heard.
  def test_closing_the_window_stops_the_play
    window = open_window
    event = Fiddle::Pointer.malloc(SDL::EVENT_BYTES, Fiddle::RUBY_FREE)
    event[0, 4] = [SDL::EVENT_QUIT].pack("L")
    SDL.binding_for(nil).SDL_PushEvent(event)
    window.show(Array.new(240 * 160, 0), 240, 160)

    assert window.stop?
  ensure
    window&.close
  end

  # A picture of a size the window was not opened for is refused in words, never read past.
  def test_a_picture_of_another_size_is_refused
    window = open_window

    error = assert_raises(ArgumentError) { window.show(Array.new(160 * 144, 0), 160, 144) }
    assert_match(/240x160 picture/, error.message)
  ensure
    window&.close
  end

  # A device keeps the console's time on the machine's own clock.
  def test_the_window_waits_on_the_machines_clock
    window = open_window
    start = window.now
    window.wait_until(start + 0.02)

    assert_operator window.now - start, :>=, 0.02
  ensure
    window&.close
  end

  # SDL3 somewhere it is not is said in plain words, naming where it looked and what to install.
  def test_sdl3_not_found_says_what_to_install
    error = assert_raises(SDL::Missing) { SDL.new(title: "TEST", scale: 1, library: "/nowhere/libSDL3.dylib") }

    assert_match(%r{cannot open SDL3 at /nowhere/libSDL3.dylib}, error.message)
    assert_match(/brew install sdl3/, error.message)
  end

  private

  def open_window
    skip "SDL3 is not installed: #{SDL::INSTALL_LINE}" unless SDL.available?

    SDL.new(title: "TEST", scale: 1)
  end
end
