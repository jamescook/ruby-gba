# frozen_string_literal: true

require "cgi/escape"
require "erb"

module RubyGBA
  module IR
    module Backends
      class JS
        # THE PAGE A GAME PLAYS IN: one HTML file holding the game and its runtime, with nothing
        # to fetch, so it opens from a disk as well as from a server. The picture is a <canvas> the
        # size of the console's screen, enlarged without smoothing so a pixel stays a square; the
        # keyboard and any controller are the gamepad (runtime/rg_page.js says which is which).
        #
        # THE PAGE IS A TEMPLATE, page.html.erb unless the build names another (`ruby-gba build
        # --format=web --page FILE`). A template is ERB, and it is handed these, each a piece of
        # finished HTML:
        #
        #   game        the canvas and the script: the one piece a page must have
        #   title       the game's name, as text
        #   style       the default look: dark, the picture centred and enlarged
        #   keys        which key is which button
        #   controller  where the page says whether a controller is in use
        #   fullscreen  a button that fills the screen with the game (the F key does too)
        #   message     where a game that stops, or a page waiting for a click, says so
        #   extras      keys, controller, fullscreen and message together, in that order
        #
        # The script finds the pieces it fills in by their id, and a page without one of them plays
        # the same, with nothing said there.
        module Page
          DEFAULT = Ractor.make_shareable(File.join(__dir__, "page.html.erb"))

          module_function

          # The page for +title+'s game, its +script+ inside, written by +template+. A template that
          # leaves the game out is a LoweringError, as anything else that stops a web build is.
          def html(title:, script:, scale: 3, template: DEFAULT)
            pieces = pieces(title: title, script: script, scale: scale)
            page = ERB.new(File.read(template, encoding: Encoding::UTF_8), trim_mode: "-").result_with_hash(pieces)
            return page if page.include?(pieces[:game])

            raise LoweringError, "The page template #{template} does not write the game, so the page would not " \
                                 "play it. Put <%= game %> in the template where the game goes."
          end

          def pieces(title:, script:, scale:)
            keys = <<~HTML.chomp
              <p>Arrows move. <kbd>X</kbd> is A, <kbd>Z</kbd> is B, <kbd>Enter</kbd> is Start, <kbd>Backspace</kbd> is
              Select, <kbd>A</kbd> and <kbd>S</kbd> are L and R, <kbd>F</kbd> fills the screen. Press a key or click
              to hear the sound.</p>
            HTML
            controller = '<p id="controller"></p>'
            fullscreen = '<button id="fullscreen" type="button">Full screen</button>'
            message = '<p id="said" hidden></p>'
            { title: CGI.escapeHTML(title.to_s), style: style(scale), game: game(script), keys: keys,
              controller: controller, fullscreen: fullscreen, message: message,
              extras: [keys, controller, fullscreen, message].join("\n") }
          end

          def game(script)
            <<~HTML.chomp
              <canvas id="screen" width="#{Screen::WIDTH}" height="#{Screen::HEIGHT}"></canvas>
              <script>
              #{script.gsub('</script', '<\/script')}
              </script>
            HTML
          end

          def style(scale)
            <<~HTML.chomp
              <style>
                :root { color-scheme: dark; }
                body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; align-items: center;
                       justify-content: center; gap: 12px; background: #111; color: #ccc;
                       font: 14px/1.4 system-ui, sans-serif; }
                canvas { width: min(#{Screen::WIDTH * scale}px, 96vw); aspect-ratio: #{Screen::WIDTH} / #{Screen::HEIGHT};
                         image-rendering: pixelated; image-rendering: crisp-edges; background: #000; }
                canvas:fullscreen { width: 100vw; height: 100vh; object-fit: contain; }
                p { margin: 0 16px; text-align: center; }
                kbd { border: 1px solid #555; border-radius: 3px; padding: 0 4px; }
                button { font: inherit; color: inherit; background: #222; border: 1px solid #555; border-radius: 4px;
                         padding: 4px 12px; cursor: pointer; }
              </style>
            HTML
          end
        end
      end
    end
  end
end
