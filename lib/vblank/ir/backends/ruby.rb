# frozen_string_literal: true

require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"
require_relative "ruby/printer"
require_relative "ruby/lowering"
require_relative "ruby/headless_run"
require_relative "ruby/checked_run"
require_relative "ruby/live_game"

module VBlank
  module IR
    module Backends
      # The game as Ruby: a program written in Ruby, played by a runtime written in Ruby, so a
      # whole game runs with nothing but Ruby — no compiler, no browser, no emulator — and is
      # checked against the interpreter on every frame like every other lowering.
      #
      # A program is a tree of statements and calls into the runtime, with no operator anywhere
      # on a game's number: every sum, comparison and shift is a runtime function (runtime/
      # rg_int32.rb) that gives IR::Int32's answer, because a Ruby Integer never wraps. Printer
      # writes the tree as one Ruby class per game, and runtime/*.rb is the rest of that class:
      # the lists, the buttons, the timers, the clock, the screen, the sound, and the driver the
      # game runs on. Every number that belongs to one console — the screen's size, how long a
      # frame is, what kind of clock the cartridge has, how the sound chip hands the noise voice on
      # — is written into the game from the console it is built for (Console::Description), so the
      # runtime plays a game as whichever console that is.
      #
      # A FRAME CAN END ANYWHERE, deep inside a routine the game called from a routine. Waiting
      # for the next one (rg_wait_vblank) calls the driver, which does the frame's work — prints
      # it, with no window, for the tests — and comes back, so the game carries on from where it
      # was. Nothing has to be turned inside out to stop part way.
      #
      # THIS LOWERING IS JUDGED BY ITS SPEED once it is right, so rubocop does not look at it
      # (.rubocop.yml): a style fix often reads better and costs the Ruby VM more instructions.
      class Ruby
        RUNTIME_DIR = Ractor.make_shareable(File.expand_path("ruby/runtime", __dir__))

        # The runtime every program carries, in the order it is put together, and the driver with
        # no window that follows it in a program the tests play.
        RUNTIME = Ractor.make_shareable(%w[rg_int32.rb rg_runtime.rb rg_list.rb rg_screen.rb rg_sound.rb rg_mix.rb
                                           rg_save.rb])
        HEADLESS_DRIVER = "rg_headless.rb"
        LIVE_DRIVER = "rg_live.rb"

        # Every function a program's runtime defines, read from its files, for each driver: what
        # Lowering#runtime_gaps holds a program's calls against.
        def self.functions_in(files) = files.flat_map { |file| File.read(File.join(RUNTIME_DIR, file)).scan(/^def (\w+)/).flatten }.uniq
        HEADLESS_FUNCTIONS = Ractor.make_shareable(functions_in(RUNTIME + [HEADLESS_DRIVER]))
        LIVE_FUNCTIONS = Ractor.make_shareable(functions_in(RUNTIME + [LIVE_DRIVER]))

        # What a program of this lowering is started with: none of the settings that would make
        # the Ruby it runs on load bundler and this library's gems, which it needs none of, and
        # which a test run started under `bundle exec` hands every program it starts.
        PROGRAM_ENVIRONMENT = Ractor.make_shareable({ "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
                                                      "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil })

        # Raised when a program needs something the runtime cannot do yet, naming the +part+ it
        # needs: a test asks it as it asks a question the lowering cannot answer, and the Ruby
        # run skips it under that part's name (Testing::RubyCheckedPlayer).
        class RuntimeGap < Native::HeadlessRun::CannotAnswer
          attr_reader :part

          def initialize(part, message)
            @part = part
            super(message)
          end
        end

        # The first line of everything the backend writes, after the line that runs it.
        WRITTEN_BY = "# Written by VBlank's Ruby backend. Do not edit; build the game again.\n"

        # The program built to run with no window, and the path to it: a script a Ruby plays (see
        # runtime/rg_headless.rb for how it is run and what it prints).
        def build_headless(program)
          lowering = Lowering.new(program)
          text, gaps = lowering.text_and_gaps(HEADLESS_FUNCTIONS)
          refuse_runtime_gaps!(gaps)
          write_program([WRITTEN_BY, "class RgGame\n", lowering.console_text, *runtime_text(RUNTIME + [HEADLESS_DRIVER]),
                         text, "end\n", "RgGame.new.rg_headless_main(ARGV)\n"].join)
        end

        # THE GAME AS AN OBJECT IN THIS PROCESS, to be played live (LiveGame). Anything its runtime
        # lacks is refused, as a test would skip.
        def live_game(program)
          lowering = Lowering.new(program)
          text, gaps = lowering.text_and_gaps(LIVE_FUNCTIONS)
          refuse_runtime_gaps!(gaps)
          LiveGame.new([lowering.console_text, *runtime_text(RUNTIME + [LIVE_DRIVER]), text].join)
        end

        private

        def refuse_runtime_gaps!(gaps)
          return if gaps.empty?

          raise RuntimeGap.new(gaps.first, "the Ruby lowering cannot play this game yet: its runtime does not " \
                                           "have #{gaps.join(', ')}")
        end

        def runtime_text(names) = names.map { |name| File.read(File.join(RUNTIME_DIR, name), encoding: Encoding::UTF_8) }

        # The script on disk, in a folder named for what it holds so two programs never write over
        # each other, written under a name of its own and then renamed into place, so two tests
        # building the same game at once each put down a whole file.
        def write_program(text)
          dir = File.join(Dir.tmpdir, "vblank-ruby", Digest::SHA256.hexdigest(text)[0, 24])
          path = File.join(dir, "vblank-headless.rb")
          return path if File.exist?(path)

          FileUtils.mkdir_p(dir)
          writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
          File.write(writing, "# frozen_string_literal: true\n#{text}")
          File.rename(writing, path)
          path
        end
      end
    end
  end
end
