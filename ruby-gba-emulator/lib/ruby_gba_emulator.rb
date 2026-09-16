# frozen_string_literal: true

require_relative "ruby_gba_emulator/version"
require_relative "ruby_gba_emulator/built_for"

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
# at all. ruby-gba reaches it through one seam, {RubyGBA::Diagnostics::Emulator}, and names
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

# The compiled half, and the require is the ordinary one any extension gem writes. What comes
# before it is a checkout's build: `rake compile` lands under lib/<the Ruby that built it>/, so
# putting that directory first means a Ruby finds its own build or none at all, rather than one
# made by another Ruby that it will refuse to load. Taken as a gem there is no such directory,
# and the require falls through to the copy RubyGems built per ABI.
built = File.join(__dir__, RubyGBAEmulator::BUILT_FOR)
$LOAD_PATH.unshift(built) if File.directory?(built) && !$LOAD_PATH.include?(built)

require "ruby_gba_emulator/ruby_gba_emulator_ext"
require_relative "ruby_gba_emulator/probe"
