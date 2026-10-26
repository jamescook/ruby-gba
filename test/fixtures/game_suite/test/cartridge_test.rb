# frozen_string_literal: true

# A game's own test of its cartridge, as a game in a repository of its own writes it: the
# library's test helper, its picture check, and nothing from VBlank's own test folder. The
# emulator comes from the ruby-gba-emulator gem.
require "vblank/testing"
require_relative "one_pixel_off"

# Run by test/vblank/testing/test_game_suite.rb.
class CartridgeTest < Minitest::Test
  include VBlank::Testing
  include VBlank::Testing::Pictures

  # The walker is drawn where holding RIGHT has moved it, so the pictures agree only if the
  # button reaches the cartridge as it reaches the interpreter, on each frame compared.
  def test_the_cartridge_draws_what_the_interpreter_draws
    game = VBlank.game "WALKER", consoles: %i[gba] do
      screen :bitmap
      x = var :x, 10
      game_loop do
        held(:right).then { x.add! 1 }
        clear_screen :black
        draw_rect_at x, 10, 4, 4, :red
      end
    end

    assert_backends_agree(game.program, frames: [2, 4, 6], keys: [:right])
  end
end
