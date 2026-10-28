#!/usr/bin/env ruby
# frozen_string_literal: true

# A score bar along the bottom of the screen, over a field that scrolls under it — on the Game
# Boy Advance, the Game Boy Color and the Super Nintendo alike.
#
# The field drifts down all the time. Hold UP and DOWN to move the ball. While the ball is near
# the bottom of the screen the bar slides down out of its way, three rows a frame, and slides back
# up once the ball has gone; a pinball table's score bar does exactly that. Every second the ball
# is in play one more pip of the bar lights up, until all of them are lit.
#
# The bar is one word, `status_bar`. It never scrolls with the field and it hides the field under
# it, so it is drawn from tiles of its own and coloured on its own. Moving it is `move_to`, a row of
# the screen, and a pip is `set_tile`, one cell of its map. On the Color the bar is the console's
# window, a layer it keeps beside its one background; on the Advance it is one of the four
# background layers; on the Super Nintendo it is one of the two, and the console is told line by
# line which layer to draw. Nothing below says which.

require_relative "../lib/vblank"

module Scoreboard
  # The ball's pixels, and the field's two kinds of row and the bar's two kinds of cell, each a
  # tile of one colour.
  BALL = <<~ART
    ..####..
    .######.
    ########
    ########
    ########
    ########
    .######.
    ..####..
  ART
  SOLID = (["########"] * 8).join("\n").freeze
  STAR = <<~ART
    ........
    ........
    ...#....
    ..###...
    ...#....
    ........
    ........
    ........
  ART

  # The field: dark rows with a star now and then, and a lighter row every eighth one, 32 rows
  # down, which is the most either console holds whole, so the drift comes round on both.
  FIELD = Ractor.make_shareable(Array.new(32) do |row|
    next "=" * 32 if (row % 8).zero?

    (0...32).map { |col| ((row * 7) + (col * 3)) % 23 == 0 ? "*" : "." }.join
  end)

  # The bar: a row of unlit pips between two edges, and a plain row under it.
  PIPS = 16
  BAR = Ractor.make_shareable(["[#{'o' * PIPS}]".ljust(32, "_"), "_" * 32])
  BAR_HEIGHT = 16

  GAME = VBlank.game("SCOREBOARD", consoles: %i[gba gbc snes]) do
    screen :tiled
    image(:ball, "#" => :white, "." => :transparent) { BALL }
    image(:dark, "#" => :blue) { SOLID }
    image(:light, "#" => :cyan) { SOLID }
    image(:star, "#" => :yellow, "." => :blue) { STAR }
    image(:bar_edge, "#" => :gray) { SOLID }
    image(:bar_plain, "#" => :black) { SOLID }
    image(:pip_off, "#" => :gray, "." => :black) { STAR }
    image(:pip_on, "#" => :green) { SOLID }
    tiles :field_tiles, "." => :dark, "=" => :light, "*" => :star
    tiles :bar_tiles, "[" => :bar_edge, "]" => :bar_edge, "_" => :bar_plain, "o" => :pip_off, "#" => :pip_on

    field = background :field, tiles: :field_tiles, map: FIELD
    rest = screen_height - BAR_HEIGHT
    bar = status_bar :score, tiles: :bar_tiles, map: BAR, top: rest
    ball = sprite :ball, at: [(screen_width / 2) - 4, screen_height / 2]
    lit = var :lit, 0

    game_loop do
      field.scroll_by 0, -1
      held(:up).then { ball.move :up, by: 2 }
      held(:down).then { ball.move :down, by: 2 }
      ball.y.clamp! 0, screen_height - 8

      # Out of the ball's way while it is low, and back once it has gone.
      (ball.y > rest - 24).then { bar.move_to (bar.top + 3).clamp(rest, screen_height) }
      (ball.y <= rest - 24).then { bar.move_to (bar.top - 3).clamp(rest, screen_height) }

      every(60) do
        (lit < PIPS).then do
          bar.set_tile lit + 1, 0, "#"
          lit.add! 1
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Scoreboard::GAME.write_if_main
