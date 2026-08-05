#!/usr/bin/env ruby
# frozen_string_literal: true

# Bird — a sprite imported straight from an .aseprite file, with no export step.
#
# assets/bird.aseprite was drawn in Aseprite: a 64x64 bird, six frames of a wing flap,
# built from seven layers over an indexed palette. `from_aseprite:` reads that native file
# directly — it composites the layers, decompresses the frames, resolves the palette, and
# reads the frame timing — so the game just points at the file the artist saved. The bird
# flaps on its own; steer it around the sky with the D-pad and it keeps flapping as it flies.
# Climb or dive and it tilts to match — `face_angle` turns the whole sprite in hardware, the
# way a bird pitches its nose up and down.
#
# This is the modern art workflow: draw in your tool, point the game at the file. (An
# Aseprite sheet exported to a PNG + JSON works the same way — pass that .json instead.)
#
# Run it to build examples/bird.gba:
#   ruby examples/bird.rb

require_relative "../lib/ruby_gba"

module Bird
  SPEED = 2 # pixels per frame the D-pad moves the bird

  GAME = RubyGBA.game("BIRD", code: "BBRD", maker: "01") do
    screen :tiled # tile mode: a background layer for the sky + a hardware sprite for the bird

    # A plain sky the bird flies over (one repeated tile).
    image(:sky, "#" => rgb(12, 18, 28)) { (["########"] * 8).join("\n") }
    tiles :air, "#" => :sky
    background :sky_bg, tiles: :air, map: Array.new(20, "#" * 30)

    # The whole animated sprite — six flapping frames — comes from the .aseprite file.
    bird = sprite :bird, at: [88, 48], from_aseprite: "assets/bird.aseprite"

    game_loop do
      bird.face_angle(0) # level unless it's climbing or diving this frame
      held(:left).then  { bird.move(-SPEED, 0) }
      held(:right).then { bird.move(SPEED, 0) }
      held(:up).then    { bird.move(0, -SPEED); bird.face_angle(335) } # climb: tip the nose up
      held(:down).then  { bird.move(0, SPEED);  bird.face_angle(25) }  # dive: tip the nose down
      bird.clamp_to_screen # keep the whole bird on screen, using its own size
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Bird::GAME.write_if_main
