# frozen_string_literal: true

module RubySNESEmulator
  # WHERE THE EMULATOR ITSELF IS: bsnes, built as a libretro core with the probe patch in
  # core/bsnes-vblank-probe.patch, which lets this gem read the console's work RAM, video RAM,
  # colour memory, sprite table and processor registers. A core built without the patch hands
  # none of those over, so it is refused rather than used.
  #
  # VBLANK_SNES_CORE names the library when it is set. Otherwise this gem's own build is used,
  # which `rake compile_core` in this gem's folder makes (see the Rakefile for the steps).
  module CoreLibrary
    SETTING = "VBLANK_SNES_CORE"
    BUILT = File.expand_path("../../core/build/bsnes_libretro.so", __dir__)

    module_function

    # The path of the core, or a LoadError saying how to make one.
    def path(env = ENV)
      named = env[SETTING]
      return named if named && File.file?(named)
      return BUILT if File.file?(BUILT)

      raise LoadError, missing_message(named)
    end

    def missing_message(named)
      where = named ? "#{SETTING} names #{named}, and there is no file there." : "There is no bsnes core built."
      <<~MESSAGE
        A Super Nintendo cartridge is played in bsnes, built as a libretro core with this gem's probe
        patch. #{where} To build it, run this in ruby-snes-emulator/:

            rake compile_core

        It needs git, make and a C++ compiler. Or set #{SETTING} to a core that is built already.
      MESSAGE
    end
  end
end
