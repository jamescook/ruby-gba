# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "js/printer"
require_relative "js/lowering"
require_relative "js/headless_run"
require_relative "js/checked_run"
require_relative "js/node"
require_relative "js/page"
require_relative "js/preview"

module RubyGBA
  module IR
    module Backends
      # The game as JavaScript: a page that plays it in a browser, drawing to a <canvas>, and the
      # same program with no page at all, which node plays for the tests.
      #
      # It stands beside the other lowerings: `rake test` plays every game in the suite as
      # JavaScript too (`rake test:lowering:js` plays only that), checked against the interpreter
      # on every frame, so a feature is not done until it works here as well.
      #
      # HOW IT IS MADE. The native lowering already says a program as a tree of statements and
      # calls into a runtime, with no operator anywhere on a game's number (see the comment atop
      # Native); JS::Lowering prints that same tree as JavaScript, and the runtime is
      # runtime/*.js, the native runtime's C written again in JavaScript, function for function,
      # since the C is itself a port of the interpreter's picture, sound and save memory. Two
      # things are JavaScript's own:
      #
      # - A NUMBER. JavaScript keeps every number as a 64-bit float, so a game's arithmetic is
      #   runtime/rg_int32.js, which brings each answer back to a signed 32-bit whole number
      #   (`| 0`, Math.imul, a test for each case IR::Int32 spells out) — the same discipline
      #   rg_int32.h keeps in C, for the opposite reason.
      # - A FRAME. A browser cannot stop a script part way through a routine to wait for the
      #   screen, so a routine that can wait is a generator, and a driver plays the game a frame
      #   at a time by asking it for the next one (see Printer).
      #
      # A DRIVER is what the game runs on: runtime/rg_headless.js, which node runs with no window
      # and which prints what the native headless program prints, so a test drives either the
      # same way (HeadlessRun); or runtime/rg_page.js, which draws to a canvas, reads the keyboard
      # and plays the sound through Web Audio.
      class JS
        # Raised when a program cannot be written as JavaScript. The same error the native
        # lowering raises, since most of what refuses a program is the lowering they share.
        LoweringError = Native::LoweringError

        RUNTIME_DIR = Ractor.make_shareable(File.expand_path("js/runtime", __dir__))

        # The runtime every program carries, in the order it is put together: the game's
        # arithmetic first, then everything that keeps the game's state. A driver follows it:
        # rg_headless.js for node, or rg_page.js inside createGame for a browser.
        RUNTIME = %w[rg_int32.js rg_runtime.js rg_list.js rg_screen.js rg_sound.js rg_mix.js rg_save.js].freeze

        # The first line of everything the backend writes.
        WRITTEN_BY = "// Written by ruby-gba's JavaScript backend. Do not edit; build the game again.\n"

        # A game's program, checked exactly the way a cartridge build checks it, as the native
        # lowering checks one (Native#checked_program), so nothing the console would refuse is
        # made for a browser instead — and then for the steps only the console can run
        # (Guardrails::Checks::WebPortability), each said with its line, which stop the build.
        def checked_program(game, settings: {}, err: $stderr)
          program = Native.new.checked_program(game, settings: settings, err: err)
          refuse_console_only_steps!(program, err)
          program
        end

        # The web build's own check, on a program however it was made: every console-only step,
        # said in plain words to +err+, and a Guardrails::ValidationError when the game can reach
        # one. One in a routine nothing calls is a warning, since the lowering leaves it out
        # (Lowering#reachable_steps is how the two agree on which those are).
        def refuse_console_only_steps!(program, err = $stderr)
          reached = Lowering.new(program).reachable_steps
          check = Guardrails::Checks::WebPortability.new(severity: :error, reached: reached)
          report = Guardrails::Validator.new(checks: [check]).run(program, autofix: false)
          report.print_findings(to: err) if err
          report.raise_on_error!
        end

        # The program written out as JavaScript: the game alone, with no runtime.
        def lower(program, title: "ruby-gba")
          Lowering.new(program, title: title).source
        end

        # THE GAME AS createGame(host): a function that makes the game afresh each time it is
        # called — the runtime, the game and the browser's driver (runtime/rg_page.js, which says
        # what +host+ may hold and what comes back) all inside it, so every game made has its own
        # state and two never meet. It is the one thing every web output wraps: the page calls it
        # (#page_script), and the module and the classic script hand it out. The text is the
        # function's declaration alone; whatever wraps it says strict mode.
        def factory(program, title: "ruby-gba")
          ["function createGame(host) {\n", *runtime_files(RUNTIME + ["rg_page.js"]), lower(program, title: title),
           "return page_create(host || {});\n}\n"].join
        end

        # The script the web build's own page carries: createGame, and the page's call of it
        # (runtime/rg_mount.js), inside a function of their own so nothing leaks into the page.
        def page_script(program, title: "ruby-gba")
          [WRITTEN_BY, "(function () {\n\"use strict\";\n", factory(program, title: title),
           *runtime_files(["rg_mount.js"]), "rg_mount_page(createGame);\n})();\n"].join
        end

        # The program built to run with no window (runtime/rg_headless.js), and the path to it,
        # which runs as a program on a machine with node. See that file for how it is run and
        # what it prints: the same as the native lowering's headless program. One game a run, so
        # it is not made through createGame.
        def build_headless(program)
          write_program([WRITTEN_BY, "(function () {\n\"use strict\";\n", *runtime_files(RUNTIME + ["rg_headless.js"]),
                         lower(program), "rg_driver_start();\n})();\n"].join)
        end

        # +game+ as ONE web page, written to +path+: the game checked as a cartridge build checks it,
        # written as JavaScript, and put in a page with nothing to fetch, which plays it in a canvas
        # when opened. +scale+ is how many times the console's picture is enlarged, and +page+ the
        # template the page is written from (see Page for what one is handed).
        def build_page(game, path, settings: {}, scale: 3, page: Page::DEFAULT, err: $stderr)
          if File.directory?(path)
            raise LoweringError, "#{path} is a folder, so the page cannot be written there. Name a file instead."
          end
          raise LoweringError, "There is no page template at #{page}. Name an .html.erb file that exists." unless File.file?(page)

          script = page_script(checked_program(game, settings: settings, err: err), title: game.title)
          File.write(path, Page.html(title: game.title, script: script, scale: scale, template: page))
          path
        end

        private

        def runtime_files(names) = names.map { |name| File.read(File.join(RUNTIME_DIR, name), encoding: Encoding::UTF_8) }

        # The script on disk, in a folder named for what it holds so two programs never write over
        # each other, written under a name of its own and then renamed into place, so two tests
        # building the same game at once each put down a whole file and never run half of the other's.
        def write_program(text)
          dir = File.join(Dir.tmpdir, "ruby-gba-js", Digest::SHA256.hexdigest(text)[0, 24])
          path = File.join(dir, "ruby-gba-headless.js")
          return path if File.exist?(path)

          FileUtils.mkdir_p(dir)
          writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
          File.write(writing, "#!/usr/bin/env node\n#{text}")
          FileUtils.chmod(0o755, writing)
          File.rename(writing, path)
          path
        end
      end
    end
  end
end
