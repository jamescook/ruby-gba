# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "js/printer"
require_relative "js/lowering"
require_relative "js/headless_run"
require_relative "js/checked_run"
require_relative "js/node"
require_relative "js/page"
require_relative "js/preview"

module VBlank
  module IR
    module Backends
      # The game as JavaScript: a page that plays it in a browser, drawing to a <canvas>, and the
      # same program with no page at all, which node plays for the tests.
      #
      # PUTTING A GAME ON THE WEB. `vblank build game.rb --format=web` writes it in one of three
      # forms, and each is described where it is written:
      #
      #   --js=page     (the default) one HTML file, game.html, that plays the game when opened;
      #                 --template FILE writes it from a page of your own (Page says what a
      #                 template is handed: the game, the buttons on the screen, the key help...)
      #   --js=module   game.mjs, for a site, a framework or a bundler: import createGame and
      #                 call it with a canvas (build_module)
      #   --js=script   game.js, for a page that loads it with a plain <script src>; the game is
      #                 on window.VBlank under the file's name, or --global NAME (build_script)
      #
      #     import { createGame } from "./game.mjs";
      #     const game = createGame({ canvas: document.querySelector("canvas") });
      #
      # Everything createGame takes besides the canvas (which keys, saves, sound, full screen,
      # pausing) and what the game it gives back can do (pause, press a button, read the save) is
      # listed atop runtime/rg_page.js, the code that reads it. --data=separate puts the game's
      # pictures, maps and sound in a file beside the code, which then has to be served rather
      # than opened from a disk (see "where a game's big tables go", below).
      #
      # `vblank preview game.rb` serves the page and builds it again from the file on every
      # reload (Preview). It plays the game as the framework understands it, so a mistake only
      # the console makes does not show there: check the cartridge before shipping one. A step
      # only the console can run (raw instructions given with `entry`) cannot be built for the
      # web, and the build names each line that has one (Guardrails::Checks::WebPortability).
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
        WRITTEN_BY = "// Written by VBlank's JavaScript backend. Do not edit; build the game again.\n"

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
        def lower(program, title: "VBlank")
          Lowering.new(program, title: title).source
        end

        # THE GAME AS createGame(host): a function that makes the game afresh each time it is
        # called — the runtime, the game and the browser's driver (runtime/rg_page.js, which says
        # what +host+ may hold and what comes back) all inside it, so every game made has its own
        # state and two never meet. It is the one thing every web output wraps: the page calls it
        # (the page's mount, runtime/rg_mount.js), and the module and the classic script hand it
        # out. The text is the function's declaration alone; whatever wraps it says strict mode.
        # Its big tables are in it (see #factory_and_data_file for them in a file of their own).
        def factory(program, title: "VBlank") = factory_and_data_file(program, title: title).first

        # createGame's text and, with +data+ :separate, the data file its big tables are in (nil
        # with them :inline). A game whose data is separate fetches it from +rg_data_beside+, which
        # whatever wraps the text declares (see #data_beside_declaration).
        def factory_and_data_file(program, title: "VBlank", data: :inline)
          text, data_file = Lowering.new(program, title: title).text_and_data_file(data: data)
          [["function createGame(host) {\n", console_text(program.described_console), *runtime_text(RUNTIME + ["rg_page.js"]), text,
            "return page_create(host || {});\n}\n"].join, data_file]
        end

        # The program built to run with no window (runtime/rg_headless.js), and the path to it,
        # which runs as a program on a machine with node. See that file for how it is run and
        # what it prints: the same as the native lowering's headless program. One game a run, so
        # it is not made through createGame.
        def build_headless(program)
          write_program(WRITTEN_BY + in_own_function(console_text(program.described_console),
                                                     *runtime_text(RUNTIME + ["rg_headless.js"]), lower(program),
                                                     "rg_driver_start();\n"))
        end

        # WHERE A GAME'S BIG TABLES GO, for each output below: +data+ :inline (the default) keeps
        # them in the script as base64, so the output is the one file and a page opens from a disk;
        # :separate writes them to a data file beside it (game.data, named for the output), which
        # the game fetches before its first frame — so a hosted game's code is small and its data
        # is cached apart from it. A browser will not fetch a file beside a page opened from a
        # disk, so a game with its data separate has to be served (`vblank preview`, any web
        # server). See runtime/rg_page.js for how a page can say where the data file is instead.

        # +game+ as ONE web page, written to +path+: the game checked as a cartridge build checks it,
        # written as JavaScript, and put in a page which plays it in a canvas when opened. +scale+ is
        # how many times the console's picture is enlarged, and +template+ the one the page is
        # written from (see Page for what one is handed).
        def build_page(game, path, settings: {}, scale: 3, template: Page::DEFAULT, data: :inline, err: $stderr)
          unless File.file?(template)
            raise LoweringError, "There is no page template at #{template}. Name an .html.erb file that exists."
          end

          write_output(game, path, settings: settings, data: data, err: err) do |text, data_file, console|
            script = WRITTEN_BY + in_own_function(data_beside_declaration(data_file, JSON.generate(data_file_name(path))),
                                                  text, *runtime_text(["rg_mount.js"]), "rg_mount_page(createGame);\n")
            Page.html(title: game.title, script: script, scale: scale, template: template, screen: console.screen_size)
          end
        end

        # +game+ as an ES MODULE, written to +path+ (game.mjs): createGame, exported by name and as
        # the module's default, and the game's title, for a page of the author's own to import —
        # through a bundler, a framework, or a <script type="module"> — and call with its canvas.
        # A data file is fetched from beside the module, wherever the page is.
        def build_module(game, path, settings: {}, data: :inline, err: $stderr)
          write_output(game, path, settings: settings, data: data, err: err) do |text, data_file|
            beside = "new URL(#{JSON.generate(data_file_name(path))}, import.meta.url).href"
            [WRITTEN_BY, data_beside_declaration(data_file, beside), text,
             "export const title = #{JSON.generate(game.title.to_s)};\n",
             "export { createGame };\nexport default createGame;\n"].join
          end
        end

        # +game+ as a CLASSIC SCRIPT, written to +path+ (game.js), for a page that loads it with a
        # plain <script src>: it puts createGame and the game's title on window.VBlank under
        # +name+ — the file's own name unless told — beside any other game's, and leaves nothing
        # else in the page's global scope. The page then calls VBlank.<name>.createGame. A data
        # file is fetched from beside the script, read from the script's own address as it loads —
        # or, for a script written into the page itself, which has no address, beside the page.
        def build_script(game, path, name: File.basename(path, ".*"), settings: {}, data: :inline, err: $stderr)
          write_output(game, path, settings: settings, data: data, err: err) do |text, data_file|
            file = JSON.generate(data_file_name(path))
            beside = "typeof document !== \"undefined\" && document.currentScript && document.currentScript.src " \
                     "? new URL(#{file}, document.currentScript.src).href : #{file}"
            WRITTEN_BY + in_own_function(data_beside_declaration(data_file, beside), text,
                                         "const root = typeof globalThis === \"undefined\" ? window : globalThis;\n",
                                         "root.VBlank = root.VBlank || {};\n",
                                         "root.VBlank[#{JSON.generate(name.to_s)}] = " \
                                         "{ createGame, title: #{JSON.generate(game.title.to_s)} };\n")
          end
        end

        private

        # The runtime files of +names+, their text in that order.
        def runtime_text(names) = names.map { |name| File.read(File.join(RUNTIME_DIR, name), encoding: Encoding::UTF_8) }

        # THE CONSOLE THE GAME IS BUILT AS, ahead of the runtime, which reads it: how big its screen
        # is, and how its clock counts a frame, from +console+ (a Console::Description). As the
        # native runtime has them (Native::ConsoleNumbers).
        def console_text(console)
          <<~JS
            const RG_SCREEN_WIDTH = #{console.screen_width}, RG_SCREEN_HEIGHT = #{console.screen_height};
            const RG_CONSOLE_TICKS_A_SECOND = #{console.cycles_a_second}, RG_CONSOLE_TICKS_A_FRAME = #{console.cycles_a_frame};
            const RG_CONSOLE_BLENDS = #{console.blends ? 1 : 0}, RG_CONSOLE_RUMBLES = #{console.rumbles ? 1 : 0};
            const RG_CLOCK_KEEPS_DATE = #{console.clock_keeps_date ? 1 : 0};
          JS
        end

        # +parts+ inside a function of their own, in strict mode, so nothing they declare leaks
        # into whatever loads them.
        def in_own_function(*parts) = ["(function () {\n\"use strict\";\n", *parts, "})();\n"].join

        # What every output does: +game+ checked and written as createGame, the text the block
        # makes of it (handed createGame's text and the data file, or nil) written to +path+, and
        # the data file beside it. Gives back +path+.
        def write_output(game, path, settings:, data:, err:)
          refuse_folder!(path)
          program = checked_program(game, settings: settings, err: err)
          text, data_file = factory_and_data_file(program, title: game.title, data: data)
          File.write(path, yield(text, data_file, program.described_console))
          File.binwrite(File.join(File.dirname(path), data_file_name(path)), data_file) if data_file
          path
        end

        # The data file's name beside the output at +path+: game.mjs's is game.data.
        def data_file_name(path) = "#{File.basename(path, '.*')}.data"

        # The JavaScript that says where a game's data file is fetched from unless the host says
        # (+beside+, an expression), for a game with a +data_file+; nothing for one without.
        def data_beside_declaration(data_file, beside) = data_file ? "const rg_data_beside = #{beside};\n" : ""

        def refuse_folder!(path)
          return unless File.directory?(path)

          raise LoweringError, "#{path} is a folder, so the game cannot be written there. Name a file instead."
        end

        # The script on disk, in a folder named for what it holds so two programs never write over
        # each other, written under a name of its own and then renamed into place, so two tests
        # building the same game at once each put down a whole file and never run half of the other's.
        def write_program(text)
          dir = File.join(Dir.tmpdir, "vblank-js", Digest::SHA256.hexdigest(text)[0, 24])
          path = File.join(dir, "vblank-headless.js")
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
