#!/usr/bin/env ruby
# frozen_string_literal: true

# Affine background — turn and resize a whole tiled layer with the D-pad.
#
# A plain `screen :tiled` background can only slide (`scroll_by`/`scroll_to`); this is
# the console's OTHER pair of background layers (BG2/BG3), which can turn and resize
# the whole picture as one piece — the Mode 7 trick behind a tilted, spinning race
# track or a title screen that zooms. Build it with `screen :affine` instead of
# `screen :tiled`, then call `rotate`/`scale` on the background handle exactly the way
# a hardware sprite's `face_angle`/`scale` already work — same names, same units,
# applied to a whole layer instead of one picture.
#
# Left/right turn the checkerboard; up/down zoom it in and out. It always pivots on
# the middle of the screen, so turning in place looks like turning in place rather
# than swinging off to one side.
#
# `screen :affine` is its own screen mode — not a flag on `screen :tiled` — because the
# console gives rotate/scale hardware to a different pair of layers than the four
# `screen :tiled` scrolls on, and a plain scroll on this layer is a friendly error (see
# `Background#scroll_by`) telling you to `rotate`/`scale` here instead.
#
# Run it to build examples/affine_bg.gba:
#   ruby examples/affine_bg.rb

require_relative "../lib/ruby_gba"

module AffineBg
  TURN_SPEED = 2
  ZOOM_STEP = 0.02
  MIN_ZOOM = 0.5
  MAX_ZOOM = 3.0

  GAME = RubyGBA.game("AFFINEBG", code: "BAFB", maker: "01") do
    screen :affine # the rotate/scale layer, not the plain-scroll one `screen :tiled` gives

    image :light, "#" => rgb(20, 20, 26) do
      <<~ART
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
    end
    image :dark, "#" => rgb(4, 4, 8) do
      <<~ART
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
    end

    tiles :checker, "L" => :light, "D" => :dark
    board = background :board, tiles: :checker, map: (0...32).map { |r|
      (0...32).map { |c| (r + c).even? ? "L" : "D" }.join
    }

    game_loop do
      held(:left).then  { board.rotate(board.angle - TURN_SPEED) }
      held(:right).then { board.rotate(board.angle + TURN_SPEED) }
      held(:up).then    { board.scale.approach MAX_ZOOM, ZOOM_STEP }
      held(:down).then  { board.scale.approach MIN_ZOOM, ZOOM_STEP }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

AffineBg::GAME.write_if_main
