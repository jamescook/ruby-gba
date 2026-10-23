# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TEST OF ruby_gba/builder/test_tint_across_screens.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY,
# kept apart so that the Game Boy Color's run never loads it (TestSuites::ADVANCE_DIR); the rest
# are in that file.
#
# The Advance's plain bitmap screen has the display mix a tint in as it draws, at eight bits a
# channel, and a screen with a colour table has it mixed into the table at five. A Game Boy Color
# has no display mix, so every screen of its mixes at five.
class TestTintAcrossScreensOnTheAdvance < Minitest::Test
  include Differential

  # A gray of 16 half way to yellow is 24 on the one and 23 on the other.
  MID_GRAY = 16 | (16 << 5) | (16 << 10)
  GRAY_TO_YELLOW = { plain: 24 | (24 << 5) | (8 << 10), tiled: 23 | (23 << 5) | (8 << 10) }.freeze

  # A tint kept across the change is mixed the way the screen it is now on mixes it.
  def test_a_tint_kept_across_is_mixed_the_way_the_new_screen_mixes
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to)

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TROUND")
      assert_equal GRAY_TO_YELLOW.fetch(to), game_player.run(handover, frames: 10).screen.pixel(120, 80),
                   "from #{from} to #{to}"
    end
  end

  # Say :plain or :tiled.
  def self.say_screen(builder, kind)
    kind == :plain ? builder.screen(:bitmap) : builder.screen(:tiled)
  end

  private

  # Two scenes on two screens and a tint half way to yellow said once before the loop. The game
  # starts on +from+'s scene and moves to +to+'s on its fourth pass, where it stays.
  def tinted_handover(from, to)
    tile = SOLID_TILE
    screens = [from, to]
    b = RubyGBA::Builder.new
    b.instance_eval do
      TestTintAcrossScreensOnTheAdvance.say_screen(self, from)
      image(:ground, "#" => MID_GRAY) { tile }
      tiles :grass, "#" => :ground
      state = var :state, 0
      ticks = var :ticks, 0
      screens.each_with_index do |kind, i|
        scene :"screen#{i}" do
          TestTintAcrossScreensOnTheAdvance.say_screen(self, kind)
          if kind == :tiled
            background :floor, tiles: :grass, map: Array.new(20) { "#" * 30 }
          else
            clear_screen MID_GRAY
          end
        end
      end
      tint :yellow, 50
      game_loop do
        ticks.add! 1
        (ticks == 4).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :screen0
          when_val 1, :screen1
        end
      end
    end
    b.finalize_program
    b.program
  end
end
