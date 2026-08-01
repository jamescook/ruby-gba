# frozen_string_literal: true

require_relative "gemba_core/version"

# GembaCore — a lean, headless libmgba binding for dev/test verification.
#
# It boots a GBA ROM and steps it one frame at a time, exposing the video and
# audio buffers and the memory bus, with no SDL2 or Tk anywhere. The C
# extension defines {GembaCore::Core} (the thin mCore wrapper) and the +KEY_*+
# constants; {GembaCore::Probe} sits on top and returns plain Ruby data.
#
# This is not the +gemba+ gem — it's a lean, unpublished core kept inside
# ruby-gba for development only, deliberately close to gemba's native code so the
# two can be re-synced.
module GembaCore
  class << self
    # Boot +rom_path+ and return a {Probe} ready to {Probe#step}.
    #
    # @param rom_path [String] path to a .gba/.gb/.gbc ROM
    # @return [Probe]
    def open(rom_path)
      Probe.new(rom_path)
    end
  end
end

# The compiled extension lives beside lib/ under ext/. Put its build dir on the
# load path so an in-repo checkout (no gem install) can require it directly.
ext_dir = File.expand_path("../ext/gemba_core_ext", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)

require "gemba_core_ext"
require_relative "gemba_core/probe"
