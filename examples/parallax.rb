#!/usr/bin/env ruby
# frozen_string_literal: true

# Parallax — two background layers that scroll at different speeds to fake depth.
#
# Declare more than one `background` and they stack: the first is the backmost, each
# later one sits in front, and a front layer's empty (see-through) tiles let the
# layer behind show through. Scroll a near layer FASTER than a far one and your eye
# reads the gap as distance — the trees rush past while the clouds drift lazily. It's
# the oldest trick for depth on flat hardware, and every side-scroller uses it.
#
# Here the FAR layer is sky with slow-drifting clouds; the NEAR layer is the ground
# and the trees on it, mostly see-through above so the sky shows. Hold left/right and
# the near layer slides twice as fast as the far one.
#
# What you never touch: which hardware layer is which, their priorities, where each
# layer's tiles and map live in video memory, or a scroll register. You write two
# `background`s and scroll each by a different amount.
#
# Its companions: examples/scroll.rb (one layer, the camera on its own) and
# examples/hero.rb (a sprite over a scrolling world).
#
# Run it to build examples/parallax.gba:
#   ruby examples/parallax.rb

require_relative "../lib/ruby_gba"

module Parallax
  FAR_SPEED = 1  # the far layer (clouds) creeps
  NEAR_SPEED = 2 # the near layer (trees/ground) slides twice as fast -> it reads as closer

  # FAR layer map (32x32 tiles): sky everywhere, with clouds scattered across the top.
  SKY = (0...32).map do |r|
    (0...32).map { |c| r.between?(2, 12) && ((r * 7) + (c * 3)) % 13 == 0 ? "c" : "." }.join
  end.freeze

  # NEAR layer map (32x32): see-through (spaces) up top so the sky shows, a row of
  # trees standing on the grass, then a grass line and dirt below. Only the bottom of
  # this reaches the 160px-tall screen; the rest sits below it.
  GROUND = (0...32).map do |r|
    (0...32).map do |c|
      if    r >= 19 then "d"                    # dirt
      elsif r == 18 then "g"                    # the grass line
      elsif r == 17 && c % 5 == 1 then "T"      # trees, standing on the grass
      else " "                                  # see-through — the far sky shows here
      end
    end.join
  end.freeze

  GAME = RubyGBA.game("PARALLAX", code: "BPLX", maker: "01") do
    screen :tiled # tile mode: two background layers, composited by the hardware

    # --- FAR layer tiles: sky and clouds (fully opaque; it's the backmost layer) ---
    image :sky, "." => rgb(11, 17, 28), "'" => rgb(14, 20, 31) do
      <<~ART
        ........
        ...'....
        ........
        .....'..
        ........
        ..'.....
        ........
        ......'.
      ART
    end
    image :cloud, "." => rgb(11, 17, 28), "#" => rgb(30, 30, 31) do
      <<~ART
        ........
        ..####..
        .######.
        ########
        .######.
        ..####..
        ........
        ........
      ART
    end

    # --- NEAR layer tiles: grass, dirt, and a tree whose edges are see-through ---
    image :grass, "#" => rgb(4, 18, 4), "^" => rgb(7, 24, 7) do
      <<~ART
        ^#^##^#^
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
    end
    image :dirt, "#" => rgb(12, 8, 4), "." => rgb(9, 6, 3) do
      <<~ART
        ########
        #.#..#.#
        ########
        ##.##.##
        ########
        #..#.#.#
        ########
        ##.#.###
      ART
    end
    # The tree's corners are transparent, so the sky (and any cloud) shows around its
    # leaves — the see-through pixels that let the far layer read as *behind* it.
    image :tree, "." => :transparent, "L" => rgb(2, 18, 4), "T" => rgb(10, 6, 2) do
      <<~ART
        ..LLLL..
        .LLLLLL.
        LLLLLLLL
        LLLLLLLL
        .LLLLLL.
        ...TT...
        ...TT...
        ..TTTT..
      ART
    end

    tiles :heavens, "." => :sky, "c" => :cloud
    tiles :scenery, "d" => :dirt, "g" => :grass, "T" => :tree

    far  = background :sky,    tiles: :heavens, map: SKY    # declared first -> the back layer
    near = background :ground, tiles: :scenery, map: GROUND # declared second -> in front

    game_loop do
      wait_vblank # scroll here, in the safe window, so both layers shift together

      # Hold a direction; the near layer moves twice as far as the far one, so the
      # trees streak past while the clouds only inch along — that speed gap is the depth.
      held(:right).then do
        far.scroll_by(FAR_SPEED, 0)
        near.scroll_by(NEAR_SPEED, 0)
      end
      held(:left).then do
        far.scroll_by(-FAR_SPEED, 0)
        near.scroll_by(-NEAR_SPEED, 0)
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Parallax::GAME.write_if_main
