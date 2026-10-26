# frozen_string_literal: true

# ONLY WHEN ASKED (GAME_SUITE_DISAGREE=1): the interpreter's screen with its top left pixel one
# colour off, so whatever this game's tests compare with the interpreter — the game as C, the
# cartridge — disagrees with it. Every test file that wants it requires this, so each disagrees
# whether or not the others are loaded.
require "vblank"

module OnePixelOff
  def shown = super.dup.tap { |pixels| pixels[0] ^= 1 }
end

if ENV["GAME_SUITE_DISAGREE"] == "1" && !VBlank::IR::Backends::Reference::Framebuffer.ancestors.include?(OnePixelOff)
  VBlank::IR::Backends::Reference::Framebuffer.prepend(OnePixelOff)
end
