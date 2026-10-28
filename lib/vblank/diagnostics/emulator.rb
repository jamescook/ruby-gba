# frozen_string_literal: true

require "tmpdir"

module VBlank
  module Diagnostics
    # The single seam between VBlank and the emulator it verifies ROMs on.
    #
    # Everything that needs a real emulator core — the {Verifier}, the standalone
    # debug/run scripts, the emulator-backed tests — goes through here, so the
    # backing emulator can be swapped in one place.
    #
    # The backend is the ruby-gba-emulator gem: a lean, headless libmgba probe. It is a gem of
    # its own rather than part of this one, because building a cartridge is pure Ruby and running
    # one is not — that half needs a C compiler and a system libmgba, and only somebody verifying
    # or profiling a ROM needs it at all. So it is not a dependency of this gem, nor loaded with
    # it; {load!} loads it when it is first needed, and raises loudly when it is absent, rather
    # than silently skipping verification.
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
      #
      # LOADED THE FIRST TIME SOMETHING NEEDS IT — a measured build, a cartridge verified, a
      # picture compared — and never by `require "vblank"`. Somebody who only builds cartridges
      # pays nothing for it, and a checkout's build that is out of date (see the emulator gem's
      # built_from.rb) stops only somebody who is about to run it.
      #
      # ON THE MAIN RACTOR. Asking for a file reads the list of places Ruby looks for one, and
      # looking in the sibling checkout WRITES that list; both are globals, which a worker Ractor
      # may not touch at all. The library starts no Ractors, so its own first use is always on
      # the main one. A test suite that plays tests in Ractors loads it before they start, which
      # vblank/testing does.
      #
      # An emulator that is there but out of date raises the gem's own error, which says how to
      # rebuild it. It is not a LoadError, so nothing below turns it into advice about a missing
      # gem, and a measured build does not carry on without measuring.
      def load!
        return true if loaded?

        require "ruby_gba_emulator"
        true
      rescue LoadError
        load_from_checkout! # raises, saying what to do about it, when the checkout has none either
        true
      end

      # Whether the emulator is loaded already. A constant lookup rather than a flag, so a worker
      # Ractor can ask it: the probe is the last thing the gem defines, after its checks passed.
      def loaded? = !defined?(::RubyGBAEmulator::Probe).nil?

      # The sibling checkout, for a clone with no bundle. Raises with what to do about it.
      def load_from_checkout!
        lib = VBlank.root.join("ruby-gba-emulator", "lib").to_s
        raise_emulator_missing!("it is not installed and there is no ruby-gba-emulator/ beside this one") unless
          File.directory?(lib)

        $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
        require "ruby_gba_emulator"
      rescue LoadError => e
        raise_emulator_missing!(e.message)
      end

      # THREE FAILURES THAT LOOK THE SAME AND NEED DIFFERENT ADVICE, and what the loader said is
      # the first thing to ask rather than the last.
      #
      # A binary built by another Ruby announces itself: the loader names the library it will not
      # link against. Read that first, because the question underneath it — is the gem in the
      # bundle — answers no for every tool run as a plain `ruby` subprocess however the load
      # failed, and then somebody is told to add a Gemfile line they already have.
      #
      # Under that the two cases are: the gem is not in the bundle at all, which is the usual one
      # and the reader is building a game; or it IS there and its C extension was never compiled,
      # which is what a `path:` entry gets you, because bundler builds extensions for gem and git
      # sources and not for path ones. A resolvable spec means the gem is present and the build is
      # what is missing.
      def raise_emulator_missing!(detail)
        raise LoadError, "#{missing_advice(detail)}\nOriginal error: #{detail}"
      end

      # How a loader says it found a library belonging to another Ruby. macOS names the libruby it
      # refuses; Linux names the one it cannot find.
      STALE_BUILD = /incompatible|libruby/i

      # +bundled+ is a parameter so that each branch can be asked for on its own: it is a fact
      # about the process, and a test of what the three messages say should not have to arrange one.
      def missing_advice(detail, bundled: Gem.loaded_specs.key?("ruby-gba-emulator"))
        return <<~STALE if detail.match?(STALE_BUILD)
          An emulator is required to run a ROM. The ruby-gba-emulator extension is built, but a
          different Ruby built it, and an extension loads only in the Ruby that made it.

              rake compile_emulator

          Each Ruby keeps a build of its own, so you do this one time for each Ruby.
        STALE

        return <<~BUILD if bundled
          An emulator is required to run a ROM. ruby-gba-emulator is in your bundle, but its C
          extension is not built — bundler does not build one for a `path:` source.

              rake compile_emulator
        BUILD

        <<~ADD
          An emulator is required to run a ROM, and ruby-gba-emulator will not load.
          Put this in your Gemfile, then run bundle install:

              git "https://github.com/jamescook/vblank.git",
                  glob: "{,ruby-gba-emulator/}*.gemspec" do
                gem "vblank"
                gem "ruby-gba-emulator"
              end

          One block for both, because both gems live in that one repository. Two separate
          `gem ... github:` lines make bundler clone it twice into one directory, and the
          clone fails.

          It builds a C extension, so it needs a C compiler and libmgba
          (brew install mgba, or apt install libmgba-dev).
        ADD
      end
      private_class_method :load_from_checkout!, :raise_emulator_missing!, :missing_advice

      # The emulator core class (loads the backend on first use).
      def core_class
        load!
        RubyGBAEmulator::Core
      end

      # THE SUPER NINTENDO'S EMULATOR is a gem of its own too, ruby-snes-emulator: bsnes, built as a
      # libretro core with a patch that hands over the console's memories, driven through Fiddle.
      # It is loaded the same way, the gem first and this repository's checkout second, and when
      # it is missing it says how to get it.
      def load_snes!
        return true if snes_loaded?

        require "ruby_snes_emulator"
        true
      rescue LoadError
        lib = VBlank.root.join("ruby-snes-emulator", "lib").to_s
        raise LoadError, "An emulator is required to run a Super Nintendo cartridge, and ruby-snes-emulator will " \
                         "not load. Put it in your Gemfile beside ruby-gba-emulator." unless File.directory?(lib)

        $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
        require "ruby_snes_emulator"
        true
      end

      def snes_loaded? = !defined?(::RubySNESEmulator::Core).nil?

      # A Super Nintendo core on a cartridge file (see RubySNESEmulator::Core). Its battery-backed
      # RAM is kept in a .srm file in +save_dir+.
      def open_snes(rom_path, save_dir: nil)
        load_snes!
        RubySNESEmulator::Core.new(rom_path, save_dir: save_dir)
      end

      # Open an emulator core on a ROM file path.
      #
      # +save_dir+ says where the cartridge's battery-backed save memory is kept. The core
      # keeps no opinion: leave it out and the emulator writes a .sav beside the ROM, and
      # creates one if it is not there. {probe} is the layer that has an opinion about that.
      def open(rom_path, save_dir: nil, bios_path: nil)
        core_class.new(rom_path, save_dir, bios_path)
      end

      # Plays +rom+ in a core of its own for the length of the block, which is handed the core,
      # and gives back what the block gave. The cartridge is written as +file_name+ into a folder
      # made for this play alone, and the folder and the core are gone when the block ends, even
      # when it raises.
      #
      # +save+ is a SaveImage for a cartridge with battery-backed save memory, or nil for one
      # without. Its bytes go in as the .sav file the emulator keeps that memory in, and what the
      # play left there comes back into the same image once the core is shut — the emulator writes
      # the file as it shuts — so one image handed to two plays is a power cycle.
      def with_cartridge(rom, file_name:, save: nil)
        kit = Console.for(rom.console)
        Dir.mktmpdir("vblank-play") do |dir|
          path = File.join(dir, file_name)
          sav = path.sub(/\.\w+\z/, "") + kit.save_file_extension
          rom.write(path)
          File.binwrite(sav, save.to_sav) if save
          core = kit.open_core(path, save_dir: dir)
          begin
            yield core
          ensure
            core.destroy
            save.replace_with_sav(save_memory_in(rom, File.binread(sav)), from: "The cartridge's save memory") if save && File.size?(sav)
          end
        end
      end

      # A CARTRIDGE WITH A CLOCK CHIP has the emulator write the chip's own state after the save
      # memory in its file, and how many bytes that is is the console's: its part of the reader says
      # where the save memory ends (Console::Kit#reading).
      def save_memory_in(rom, file) = Console.for(rom.console).reading::SAVE_FILE.memory_in(file)
      private_class_method :save_memory_in

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

      # THE QUESTIONS THE EMULATOR ANSWERS ABOUT A WHOLE SCREEN, for a screen it handed over:
      # which colours it holds, whether it is all one colour, how bright it is, and whether
      # and where it differs from another.
      #
      #   Emulator.screen_questions.same?(one, other)
      #
      # A screen is 38,400 pixels, and going through them in Ruby is a number made and thrown
      # away for every one, which is far more work than running the frame was. A test that
      # asks something of the whole screen on every frame of a long run spends nearly all of
      # its time asking, so the asking is done in the emulator's own code, in one pass over
      # the bytes.
      #
      # Each answer is given at the precision a console shows — five bits each of red, green
      # and blue. The emulator keeps eight, and what it holds below the five is its own
      # working, which differs with how it reached a colour; so two screens that are
      # different bytes can still be one picture.
      def screen_questions
        load!
        RubyGBAEmulator::Screen
      end

      # Whether the backend can be loaded, loading it if so. For the caller that legitimately
      # degrades rather than fails — a measured build with no emulator to measure on, the
      # standalone debug scripts. An emulator that is there but out of date still raises.
      # Emulator-backed tests must NOT use this to skip: the emulator is required, so a load
      # failure there is a real error (see the module note).
      def available?
        load!
        true
      rescue LoadError
        false
      end
    end
  end
end
