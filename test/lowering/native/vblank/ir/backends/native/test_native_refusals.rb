# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# What a desktop build refuses, and that it says so in plain words before anything is written.
class TestNativeRefusals < Minitest::Test
  include NativeComparison

  LoweringError = VBlank::IR::Backends::Native::LoweringError

  # Bytes of the console's own machine code only mean something on the console.
  def test_raw_machine_code_is_refused_by_name
    program = program_of do
      entry { nop }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_includes error.message, ":raw"
  end

  # A song with more parts on the square wave than the console has such voices stops the program
  # that plays it, saying so. Only a song built by hand can be one: a game's own is refused before
  # this, by the checks a cartridge build makes.
  def test_a_song_with_three_square_parts_stops_the_program
    part = VBlank::Audio::Music::Part.new(events: [[0, 262]])
    program = VBlank::IR::Build.program(
      VBlank::IR::Build.song(:crowd, total_frames: 10, voices: [part, part, part]),
      VBlank::IR::Build.play_song(:crowd),
      VBlank::IR::Build.loop_(VBlank::IR::Build.wait_vblank)
    )

    error = assert_raises(VBlank::IR::ProgramError) { Native::HeadlessRun.new.run(program, frames: 3) }
    assert_match(/more parts on the square wave than the 2 there are/, error.message)
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
    game = VBlank.game("REFUSED", consoles: %i[gba]) do
      screen :tiled
      game_loop { pixel 10, 10, :red } # painting on a tiled screen: a black screen on the console
    end

    assert_raises(VBlank::ROMError) { Native.new.checked_program(game, err: nil) }
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
end
