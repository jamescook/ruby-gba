# frozen_string_literal: true

require "ruby_gba"

# The game, kept where this game keeps its code rather than under lib/.
module Walker
  GAME = RubyGBA.game "WALKER", consoles: %i[gba] do
    x = var :x, 0
    game_loop do
      held(:right).then { x.add! 1 }
      pixel 10, 10, :red
    end
  end
end
