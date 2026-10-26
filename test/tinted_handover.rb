# frozen_string_literal: true

# A tint left on while a game changes screen: the game the tests of a tint across a change of
# screen play, on every console (test_tint_across_screens.rb) and on the Advance's alone
# (test_tint_across_screens_on_the_advance.rb).
module TintedHandover
  # Say one of the three screens: :plain, :tear_free or :tiled.
  def self.say_screen(builder, kind)
    case kind
    when :plain then builder.screen :bitmap
    when :tear_free then builder.screen :bitmap, tear_free: true
    else builder.screen :tiled
    end
  end

  private

  # Two scenes on two screens and a tint said once before the loop, which takes +ground+
  # toward +toward+. The game starts on +from+'s scene and moves to +to+'s on its fourth pass,
  # where it stays. +before_loop+ is said after the tint.
  def tinted_handover(from, to, amount: 50, ground: :green, toward: :red, &before_loop)
    tile = Minitest::Test::SOLID_TILE
    screens = [from, to]
    b = VBlank::Builder.new
    b.instance_eval do
      TintedHandover.say_screen(self, from)
      image(:ground, "#" => ground) { tile }
      tiles :grass, "#" => :ground
      state = var :state, 0
      ticks = var :ticks, 0
      level = var :level, 0
      screens.each_with_index do |kind, i|
        scene :"screen#{i}" do
          TintedHandover.say_screen(self, kind)
          if kind == :tiled
            background :floor, tiles: :grass, map: Array.new(20) { "#" * 30 }
          else
            clear_screen ground
          end
        end
      end
      level.set! 50
      tint toward, amount == :worked_out ? level : amount
      instance_eval(&before_loop) if before_loop
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

  # The colour in the middle of the screen once the game is on its second screen.
  def shown_after_handover(handover)
    game_player.run(handover, frames: 10).screen.pixel(120, 80)
  end
end
