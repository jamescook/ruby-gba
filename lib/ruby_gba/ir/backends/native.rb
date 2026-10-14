# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "native/zig"
require_relative "native/names"
require_relative "native/c"
require_relative "native/printer"
require_relative "native/drawn_sprites"
require_relative "native/picture"
require_relative "native/sound_log"
require_relative "native/sound"
require_relative "native/saving"
require_relative "native/lowering"
require_relative "native/headless_run"

module RubyGBA
  module IR
    module Backends
      # The game as a program for a desktop computer: the IR written out as C, built by zig into
      # one executable. The cartridge stays the main thing this library makes; this is a second
      # one beside it.
      #
      # It TRAILS the other two backends rather than standing beside them. `rake test` never
      # runs its tests (`rake test:native` does), and a feature that works on the console and
      # in the interpreter is done without it; anything it cannot do yet is a gap to fill here.
      #
      # How it writes C, and why that way (doc/research/writing-c.md has the reading behind it):
      #
      # - The game's arithmetic lives in runtime/rg_int32.h, a C function for each thing
      #   IR::Int32 and the interpreter do with a number. C leaves several of the things a game
      #   does with numbers undefined — running off the end of a number, dividing the lowest
      #   number by -1, shifting by 32 — and an optimising compiler is allowed to assume they
      #   never happen. Those functions work on the unsigned kind of number, which C does
      #   promise wraps, and test the rest.
      # - The C this writes never uses an operator on one of the game's numbers; it calls one
      #   of those functions. That is what keeps it correct, and it is also why the precedence
      #   of C's operators, and && skipping its right side, never come up.
      # - It never names SDL, nor a file. The picture, the buttons, the sound and the save memory
      #   go through the runtime (runtime/rg_runtime.h and the headers beside it), which a
      #   desktop build links against SDL and a test links against a version that has no window
      #   at all.
      # - It is checked by running, against Backends::Reference, and never by comparing the C
      #   it wrote against C somebody wrote down.
      class Native
        # A game's program, checked exactly the way a cartridge build checks it — by making the
        # cartridge, every guardrail on, and taking the program that build checked. So nothing
        # the console would refuse can be built for a desktop instead: a desktop has room for
        # what the console does not, and a game that only works there is not this library's.
        # Guardrail warnings are printed to +err+, as the cartridge build prints them.
        def checked_program(game, settings: {}, err: $stderr)
          game.build_rom(profile: false, out: nil, err: err, settings: settings).built.source_program
        end

        # The runtime's C files each kind of build compiles beside the game's. The desktop build
        # carries the windowless runtime too, so the program a player runs can be driven by a
        # test with --headless.
        SHARED_RUNTIME = %w[rg_headless.c rg_mix.c rg_runtime.c rg_save.c rg_screen.c rg_sound.c].freeze
        HEADLESS_RUNTIME = (["rg_headless_main.c"] + SHARED_RUNTIME).freeze
        DESKTOP_RUNTIME = (["rg_sdl.c"] + SHARED_RUNTIME).freeze

        # The program written out as C, as one file's text. A program from a game should come
        # through #checked_program first. +title+ is the game's name, for the window.
        def lower(program, title: "ruby-gba")
          Lowering.new(program, title: title).source
        end

        # The program built into a program with no window (runtime/rg_headless.c), and the
        # path to it. See that file for how it is run and what it prints. Built with zig on
        # its own, with no SDL to fetch or compile, which is what keeps the tests quick.
        def build_headless(program, mode: :checked)
          Zig.compile_without_sdl([write_source(lower(program)), *HEADLESS_RUNTIME.map { |file| File.join(Zig::RUNTIME_DIR, file) }],
                                  mode: mode)
        end

        # +game+ built into ONE program for this computer, with a window, written to +path+: the
        # game checked as a cartridge build checks it, written as C, and compiled with SDL3 by
        # zig into an executable that needs nothing installed beside it. The first build fetches
        # SDL's source and compiles it, which takes a while once; every build after that reuses it.
        def build_desktop(game, path, settings: {}, err: $stderr)
          if File.directory?(path)
            raise LoweringError, "#{path} is a folder, so the program cannot be written there. Name a file instead."
          end

          source = lower(checked_program(game, settings: settings, err: err), title: game.title)
          Dir.mktmpdir("ruby-gba-native") do |dir|
            src = File.join(dir, "src")
            FileUtils.mkdir_p(src)
            File.write(File.join(src, "game.c"), source)
            Dir.glob(File.join(Zig::RUNTIME_DIR, "*")).each { |file| FileUtils.cp(file, src) }
            exe = Zig.build_with_sdl(src, ["game.c", *DESKTOP_RUNTIME], name: "game", prefix: File.join(dir, "out"))
            FileUtils.cp(exe, path)
          end
          FileUtils.chmod(0o755, path)
          path
        end

        private

        # The C on disk, where the compiler can read it, in a folder named for what it holds so
        # two programs never write over each other. Written under a name of its own and then
        # renamed into place, so two threads building the same game at once — tests run side by
        # side — each put down a whole file and never read half of the other's.
        def write_source(text)
          dir = File.join(Dir.tmpdir, "ruby-gba-native", "src-#{Digest::SHA256.hexdigest(text)[0, 24]}")
          path = File.join(dir, "game.c")
          return path if File.exist?(path)

          FileUtils.mkdir_p(dir)
          writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
          File.write(writing, text)
          File.rename(writing, path)
          path
        end
      end
    end
  end
end
