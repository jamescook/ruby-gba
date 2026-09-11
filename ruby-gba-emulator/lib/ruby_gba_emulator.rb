# frozen_string_literal: true

require_relative "ruby_gba_emulator/version"

# RubyGBAEmulator — a lean, headless libmgba binding for dev/test verification.
#
# It boots a GBA ROM and steps it one frame at a time, exposing the video and
# audio buffers and the memory bus, with no SDL2 or Tk anywhere. The C
# extension defines {RubyGBAEmulator::Core} (the thin mCore wrapper) and the
# +KEY_*+ constants; {RubyGBAEmulator::Probe} sits on top and returns plain
# Ruby data.
#
# It is a gem of its own rather than part of ruby-gba, because building a
# cartridge is pure Ruby and running one is not: this half needs a C compiler
# and a system libmgba, and only somebody verifying or profiling a ROM needs it
# at all. ruby-gba reaches it through one seam, {RubyGBA::Emulator}, and names
# nothing from here anywhere else.
module RubyGBAEmulator
  class << self
    # Boot +rom_path+ and return a {Probe} ready to {Probe#step}.
    #
    # @param rom_path [String] path to a .gba/.gb/.gbc ROM
    # @param save_dir [String, nil] where the cartridge's save memory lives — see {Probe#initialize}
    # @param bios_path [String, nil] a BIOS image to boot through
    # @return [Probe]
    def open(rom_path, save_dir: nil, bios_path: nil)
      Probe.new(rom_path, save_dir: save_dir, bios_path: bios_path)
    end
  end
end

# The compiled half, built by extconf into lib/ruby_gba_emulator/ — an ordinary require, the
# way any extension gem does it. `rake compile` puts it there in a checkout; `bundle install`
# puts it there per Ruby ABI for anyone taking this as a gem.
require "ruby_gba_emulator/ruby_gba_emulator_ext"
require_relative "ruby_gba_emulator/probe"
