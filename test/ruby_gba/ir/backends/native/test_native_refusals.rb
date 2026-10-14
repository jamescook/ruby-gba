# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# What a desktop build refuses, and that it says so in plain words before anything is written.
class TestNativeRefusals < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  LoweringError = RubyGBA::IR::Backends::Native::LoweringError

  # Bytes of the console's own machine code only mean something on the console.
  def test_raw_machine_code_is_refused_by_name
    program = program_of do
      entry { nop }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_includes error.message, ":raw"
  end

  # A kind this backend trails on is named, with the part of the work it belongs to.
  def test_a_kind_not_written_yet_is_refused_by_name
    program = program_of do
      clock = timer :clock, per_second: 30
      seen = var :seen, 0
      game_loop { seen.set! clock.ticks }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/cannot make yet \(timers\)/, error.message)
  end

  # Sound the desktop cannot play yet is refused by name, rather than left out of what it plays.
  def test_a_sound_not_played_yet_is_refused_by_name
    program = program_of do
      enable_sound
      crash = sample :crash, pcm: [60, -60] * 400, rate: 8000
      game_loop { crash.play }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/:play_sample.*cannot make yet \(sound\)/, error.message)
  end

  # A part on one of the console's own voices is played; one that plays a recording is not yet.
  def test_a_song_part_that_plays_a_recording_is_refused_by_name
    program = program_of do
      enable_sound
      instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
      song(:tune) do
        voice(:pad, plays: :wave) { note :C4, :quarter }
        voice(:keys, plays: :piano) { note :C4, :quarter }
      end
      play_song :tune
      game_loop {}
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/song :tune.*plays a recording/, error.message)
  end

  # A song with more parts on the square wave than the console has such voices stops the program
  # that plays it, saying so. Only a song built by hand can be one: a game's own is refused before
  # this, by the checks a cartridge build makes.
  def test_a_song_with_three_square_parts_stops_the_program
    part = RubyGBA::Audio::Music::Part.new(events: [[0, 262]])
    program = RubyGBA::IR::Build.program(
      RubyGBA::IR::Build.song(:crowd, total_frames: 10, voices: [part, part, part]),
      RubyGBA::IR::Build.play_song(:crowd),
      RubyGBA::IR::Build.loop_(RubyGBA::IR::Build.wait_vblank)
    )

    error = assert_raises(Native::Zig::Error) { Native::HeadlessRun.new.run(program, frames: 3) }
    assert_match(/3 parts on the square wave, and the most is 2/, error.message)
  end

  # What the desktop's picture cannot draw yet is refused, by name, rather than drawn wrong.
  #
  # A frame that ends while drawing is held inside an area: the interpreter reads the screen
  # through that area then, and the desktop build reads all of it.
  def test_a_frame_that_ends_inside_a_held_area_is_refused_by_name
    assert_refused_picture(/frame that ends inside an `inside` block/) do
      screen :bitmap
      clear_screen :blue
      n = var :n, 0
      inside(40, 30, 100, 60) { game_loop { n.add! 1 } }
    end
  end

  # Two scenes may each declare a background by the same name; the desktop build would draw the
  # second one's map for both.
  def test_two_backgrounds_with_one_name_are_refused_by_name
    assert_refused_picture(/two backgrounds with one name \(room\)/) do
      screen :tiled
      var :state, 0
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :wall, "#" => :brick
      scene(:first) { background :room, tiles: :wall, map: ["##  "] }
      scene(:second) { background :room, tiles: :wall, map: ["  ##"] }
      game_loop do
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end
  end

  # A run of sprites drawn in an order the game works out is swapped into the frame by position,
  # and the desktop build places its sprites by name. Those are the same thing in every game the
  # builder makes; a tree where they are not is refused rather than drawn some other way.
  def test_a_draw_order_whose_sprites_are_not_side_by_side_is_refused
    program = with_draw_orders_written_by_hand(three_sprites_and_a_list) { |names| [[[names[0], names[2]], :order]] }

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/not side by side/, error.message)
  end

  def test_a_sprite_in_two_draw_orders_is_refused
    program = with_draw_orders_written_by_hand(three_sprites_and_a_list) do |names|
      [[names[0, 2], :order], [names[1, 2], :order]]
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/in two runs/, error.message)
  end

  # The desktop build checks a game the way the cartridge build does, so a game the console
  # would refuse is refused here too, by the same friendly error.
  def test_a_game_the_cartridge_build_refuses_is_refused_for_the_desktop
    game = RubyGBA.game("REFUSED") do
      game_loop { pixel 10, 10, :red } # drawing with no screen chosen: a black screen on the console
    end

    assert_raises(RubyGBA::ROMError) { Native.new.checked_program(game, err: nil) }
  end

  # A routine nothing calls is left out of the C altogether, so a table only it reads cannot
  # leave an unused table behind for the compiler to stop on.
  def test_a_routine_nothing_calls_leaves_nothing_behind
    program = program_of do
      odd = table :odd, [1, 2, 3]
      n = var :n, 0
      func(:helper) { n.set! odd[n] }
      func(:never) { call :helper }
      game_loop { n.add! 1 }
    end

    assert_native_matches_reference program, frames: 2
  end

  private

  def three_sprites_and_a_list
    program_of do
      screen :tiled
      image :dot, "#" => :red do "########\n" * 8 end
      %i[one two three].each_with_index { |name, i| sprite name, at: [10 * i, 10], facing: { down: :dot } }
      list :order, capacity: 4, width: :byte
      game_loop {}
    end
  end

  def assert_refused_picture(message, &block)
    error = assert_raises(LoweringError) { Native.new.lower(program_of(&block)) }
    assert_match message, error.message
    assert_match(/desktop build cannot draw yet/, error.message)
  end
end
