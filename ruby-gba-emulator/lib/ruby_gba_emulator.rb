# frozen_string_literal: true

require_relative "ruby_gba_emulator/version"
require_relative "ruby_gba_emulator/built_for"
require_relative "ruby_gba_emulator/built_from"

# The compiled half, and the require is the ordinary one any extension gem writes. What comes
# before it is a checkout's build: `rake compile` lands under lib/<the Ruby that built it>/, so
# putting that directory first means a Ruby finds its own build or none at all, rather than one
# made by another Ruby that it will refuse to load. Taken as a gem there is no such directory,
# and the require falls through to the copy RubyGems built per ABI.
#
# A checkout's build is also the one that can be out of date: its Ruby half changes the moment
# new code is pulled, and its compiled half only when somebody builds. So that build is checked
# against the source beside it before anything uses it (see built_from.rb). A gem's build comes
# from the source it was installed with and is not checked.
built = File.join(__dir__, RubyGBAEmulator::BUILT_FOR)
checkout_build = File.directory?(built)
$LOAD_PATH.unshift(built) if checkout_build && !$LOAD_PATH.include?(built)

require "ruby_gba_emulator/ruby_gba_emulator_ext"
RubyGBAEmulator.refuse_out_of_date_build! if checkout_build
require_relative "ruby_gba_emulator/probe"

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
# at all. ruby-gba reaches it through one seam, {VBlank::Diagnostics::Emulator}, and names
# nothing from here anywhere else.
#
# Its methods are defined last, after the compiled half has loaded. A load that fails stops this
# file part way, and the next `require` runs it again from the top, so a method defined above
# the failure would be defined again on every try, with a warning from Ruby each time.
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
