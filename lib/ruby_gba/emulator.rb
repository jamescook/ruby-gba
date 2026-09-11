# frozen_string_literal: true

module RubyGBA
  # The single seam between ruby-gba and the emulator it verifies ROMs on.
  #
  # Everything that needs a real emulator core — the {Verifier}, the standalone
  # debug/run scripts, the emulator-backed tests — goes through here, so the
  # backing emulator can be swapped in one place.
  #
  # The backend is the ruby-gba-emulator gem: a lean, headless libmgba probe. It is a gem of
  # its own rather than part of this one, because building a cartridge is pure Ruby and running
  # one is not — that half needs a C compiler and a system libmgba, and only somebody verifying
  # or profiling a ROM needs it at all. So it is not a dependency of this gem; {load!} raises
  # loudly when it is absent, rather than silently skipping verification.
  module Emulator
    module_function

    # Load the emulator backend. Raises a clear, actionable error when it isn't there.
    #
    # THE GEM FIRST, THE CHECKOUT SECOND, and the order is the whole point. The gem declares
    # its C extension, so a Gemfile line builds it — per Ruby ABI, which means changing Ruby
    # rebuilds it rather than leaving a binary compiled for another one.
    #
    # The fallback is this repository's own checkout, which keeps its copy of the emulator in a
    # sibling directory. Convenient, and it is the arrangement that hid the problem for years —
    # a vendored path always resolves, so nobody found out that nothing was ever building this
    # for anyone else.
    def load!
      require "ruby_gba_emulator"
    rescue LoadError
      load_from_checkout!
    end

    # The sibling checkout, for a clone with no bundle. Raises with what to do about it.
    def load_from_checkout!
      lib = File.expand_path("../../ruby-gba-emulator/lib", __dir__)
      raise_missing!("it is not installed and there is no ruby-gba-emulator/ beside this one") unless
        File.directory?(lib)

      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require "ruby_gba_emulator"
    rescue LoadError => e
      raise_missing!(e.message)
    end

    # TWO FAILURES THAT LOOK THE SAME AND NEED OPPOSITE ADVICE.
    #
    # Either the gem is not in your bundle at all — the usual case, and the reader is building a
    # game — or it IS there and its C extension was never compiled, which is what a `path:`
    # entry gets you, because bundler builds extensions for gem and git sources and not for
    # path ones. Telling somebody to add a line they already have is the worst of both, so ask
    # which it is: a resolvable spec means the gem is present and the build is what is missing.
    def raise_missing!(detail)
      raise LoadError, "#{missing_advice}\nOriginal error: #{detail}"
    end

    def missing_advice
      return <<~BUILD if Gem.loaded_specs.key?("ruby-gba-emulator")
        An emulator is required to run a ROM. ruby-gba-emulator is in your bundle, but its C
        extension is not built — bundler does not build one for a `path:` source.

            rake compile_emulator

        If you have just changed Ruby version, the build is stale rather than missing: a
        compiled extension is tied to the Ruby that built it. Run `rake clean` in
        ruby-gba-emulator/ first.
      BUILD

      <<~ADD
        An emulator is required to run a ROM, and ruby-gba-emulator will not load.
        Add this to your Gemfile, then run bundle install:

            gem "ruby-gba-emulator", github: "jamescook/ruby-gba",
                glob: "ruby-gba-emulator/ruby-gba-emulator.gemspec"

        It builds a C extension, so it needs a C compiler and libmgba
        (brew install mgba, or apt install libmgba-dev).
      ADD
    end
    private_class_method :load_from_checkout!, :raise_missing!, :missing_advice

    # The emulator core class (loads the backend on first use).
    def core_class
      load!
      RubyGBAEmulator::Core
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
      RubyGBAEmulator.open(rom_path, save_dir: save_dir, bios_path: bios_path)
    end

    # Whether the backend can be loaded. For the rare caller that legitimately
    # degrades rather than fails — the standalone debug scripts. Emulator-backed
    # tests must NOT use this to skip: the emulator is required, so a load failure
    # there is a real error (see the module note).
    def available?
      load!
      true
    rescue LoadError
      false
    end
  end
end
