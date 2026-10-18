# frozen_string_literal: true

require "cgi/escape"

module RubyGBA
  module IR
    module Backends
      class JS
        # THE PAGE A GAME PLAYS IN: one HTML file holding the game and its runtime, with nothing
        # to fetch, so it opens from a disk as well as from a server. The picture is a <canvas> the
        # size of the console's screen, enlarged without smoothing so a pixel stays a square; the
        # keyboard is the gamepad (runtime/rg_page.js says which key is which button).
        module Page
          module_function

          def html(title:, script:, scale: 3)
            name = CGI.escapeHTML(title.to_s)
            width = Screen::WIDTH * scale
            <<~HTML
              <!doctype html>
              <html lang="en">
              <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>#{name}</title>
              <style>
                :root { color-scheme: dark; }
                body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; align-items: center;
                       justify-content: center; gap: 12px; background: #111; color: #ccc;
                       font: 14px/1.4 system-ui, sans-serif; }
                canvas { width: min(#{width}px, 96vw); aspect-ratio: #{Screen::WIDTH} / #{Screen::HEIGHT};
                         image-rendering: pixelated; image-rendering: crisp-edges; background: #000; }
                p { margin: 0 16px; text-align: center; }
                kbd { border: 1px solid #555; border-radius: 3px; padding: 0 4px; }
              </style>
              </head>
              <body>
              <canvas id="screen" width="#{Screen::WIDTH}" height="#{Screen::HEIGHT}"></canvas>
              <p>Arrows move. <kbd>X</kbd> is A, <kbd>Z</kbd> is B, <kbd>Enter</kbd> is Start, <kbd>Backspace</kbd> is
              Select, <kbd>A</kbd> and <kbd>S</kbd> are L and R. Press a key or click to hear the sound.</p>
              <p id="controller"></p>
              <p id="said" hidden></p>
              <script>
              #{script.gsub('</script', '<\/script')}
              </script>
              </body>
              </html>
            HTML
          end
        end
      end
    end
  end
end
