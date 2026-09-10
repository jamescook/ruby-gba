# frozen_string_literal: true

module RubyGBA
  # The single seam between ruby-gba and the emulator it verifies ROMs on.
  #
  # Everything that needs a real emulator core — the {Verifier}, the standalone
  # debug/run scripts, the emulator-backed tests — goes through here, so the
  # backing emulator can be swapped in one place.
  #
  # The backend is gemba-core: a lean, headless libmgba probe vendored in-repo
  # under gemba-core/ (not a published gem). It has a C extension that must be
  # built — `rake test:mgba`, or the compile step `rake test` runs first. It is
  # required, not optional: {load!} raises loudly when it can't be loaded, so a
  # missing build fails rather than silently skipping verification.
  module Emulator
    module_function

    # Load the emulator backend, putting gemba-core's in-repo lib on the load
    # path first. Raises a clear, actionable error when it isn't built.
    def load!
      lib = File.expand_path("../../gemba-core/lib", __dir__)
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require "gemba_core"
    rescue LoadError => e
      raise LoadError, "gemba-core is required to run ROMs in an emulator, but it isn't " \
                       "loadable — build its C extension with `rake test:mgba`. " \
                       "Original error: #{e.message}"
    end

    # The emulator core class (loads the backend on first use).
    def core_class
      load!
      GembaCore::Core
    end

    # Open an emulator core on a ROM file path.
    #
    # +save_dir+ says where the cartridge's battery-backed save memory is kept. The core
    # keeps no opinion: leave it out and the emulator writes a .sav beside the ROM, and
    # creates one if it is not there. {probe} is the layer that has an opinion about that.
    def open(rom_path, save_dir: nil, bios_path: nil)
      core_class.new(rom_path, save_dir, bios_path)
    end

    # Open a high-level probe on a ROM file path — the API that runs frames, reads
    # memory, and measures how many of a frame's scanlines the CPU burns. The analyzer
    # profiles through this.
    #
    # It writes no save file beside the ROM unless +save_dir+ says to, so profiling a game
    # twice profiles the same game — a saved high score carried from one run into the next
    # would quietly make them different games.
    def probe(rom_path, save_dir: nil, bios_path: nil)
      load!
      GembaCore.open(rom_path, save_dir: save_dir, bios_path: bios_path)
    end

    # Whether the backend can be loaded. For the rare caller that legitimately
    # degrades rather than fails — the standalone debug scripts. Emulator-backed
    # tests must NOT use this to skip: gemba-core is required, so a load failure
    # there is a real error (see the module note).
    def available?
      load!
      true
    rescue LoadError
      false
    end
  end
end
