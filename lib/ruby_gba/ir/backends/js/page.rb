# frozen_string_literal: true

require "cgi/escape"
require "erb"

module RubyGBA
  module IR
    module Backends
      class JS
        # THE PAGE A GAME PLAYS IN: one HTML file holding the game and its runtime, with nothing
        # to fetch unless its data was built separate (JS#build_page), so it opens from a disk as
        # well as from a server. The picture is a <canvas> the
        # size of the console's screen, enlarged without smoothing so a pixel stays a square; the
        # keyboard and any controller are the gamepad (runtime/rg_page.js says which is which).
        #
        # THE PAGE IS A TEMPLATE, page.html.erb unless the build names another (`ruby-gba build
        # --format=web --template FILE`). A template is ERB, and it is handed these, each a piece of
        # finished HTML:
        #
        #   game        the canvas and the script: the one piece a page must have
        #   title       the game's name, as text
        #   style       the default look: dark, the picture centred and enlarged
        #   keys        which key is which button
        #   controller  where the page says whether a controller is in use
        #   fullscreen  a button that fills the screen with the game (the F key does too)
        #   pause       a checkbox, ticked, for pausing the game while another window has the
        #               keyboard; write your own <input type="checkbox" id="pause"> without
        #               `checked` to start with it off, and a page without one pauses
        #   touchpad    the console's buttons on the screen, for a phone or a tablet, shown only on
        #               a screen a finger points at
        #   message     where a game that stops, or a page waiting for a click, says so
        #   extras      touchpad, keys, controller, fullscreen, pause and message together, in
        #               that order
        #
        # The script finds the pieces it fills in by their id, and a page without one of them plays
        # the same, with nothing said there.
        module Page
          DEFAULT = Ractor.make_shareable(File.join(__dir__, "page.html.erb"))

          # Every pixel of the console's picture drawn as a square however big the canvas is drawn,
          # rather than smoothed into its neighbours. On the canvas itself, so no template loses
          # it; crisp-edges first, for a browser that does not know pixelated.
          SQUARE_PIXELS = "image-rendering: crisp-edges; image-rendering: pixelated"

          module_function

          # The page for +title+'s game, its +script+ inside, written by +template+. A template that
          # leaves the game out is a LoweringError, as anything else that stops a web build is.
          def html(title:, script:, scale: 3, template: DEFAULT)
            pieces = pieces(title: title, script: script, scale: scale)
            page = ERB.new(File.read(template, encoding: Encoding::UTF_8), trim_mode: "-").result_with_hash(pieces)
            return page if page.include?(pieces[:game])

            raise LoweringError, "The page template #{template} does not write the game, so the page will not " \
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
            pause = '<label><input type="checkbox" id="pause" checked> Pause when another window is in front</label>'
            message = '<p id="said" hidden></p>'
            { title: CGI.escapeHTML(title.to_s), style: style(scale), game: game(script), keys: keys,
              controller: controller, fullscreen: fullscreen, pause: pause, touchpad: touchpad, message: message,
              extras: [touchpad, keys, controller, fullscreen, pause, message].join("\n") }
          end

          # THE PAD ON THE SCREEN, for a phone or a tablet, which has no keys: the console's buttons
          # laid out as a GBA lays them out — L and R along the top, the cross on the left, B and A
          # on the right, Select and Start between — each pressing its button while a finger is on
          # it (runtime/rg_mount.js finds them by id, "pad-" and the button's name). It is hidden
          # until the page finds a screen a finger points at.
          def touchpad
            key = ->(name, label, area) { %(<button id="pad-#{name}" type="button" style="grid-area: #{area}">#{label}</button>) }
            [%(<div id="touchpad" class="touchpad" hidden>),
             key.call("l", "L", "l"), key.call("r", "R", "r"),
             %(<div class="pad-cross">), key.call("up", "▲", "up"), key.call("left", "◀", "left"),
             key.call("right", "▶", "right"), key.call("down", "▼", "down"), "</div>",
             %(<div class="pad-middle">), key.call("select", "SELECT", "auto"), key.call("start", "START", "auto"), "</div>",
             %(<div class="pad-face">), key.call("b", "B", "b"), key.call("a", "A", "a"), "</div>",
             "</div>"].join("\n")
          end

          def game(script)
            <<~HTML.chomp
              <canvas id="screen" width="#{Screen::WIDTH}" height="#{Screen::HEIGHT}" style="#{SQUARE_PIXELS}"></canvas>
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
                         background: #000; }
                canvas:fullscreen { width: 100vw; height: 100vh; object-fit: contain; }
                p { margin: 0 16px; text-align: center; }
                kbd { border: 1px solid #555; border-radius: 3px; padding: 0 4px; }
                button { font: inherit; color: inherit; background: #222; border: 1px solid #555; border-radius: 4px;
                         padding: 4px 12px; cursor: pointer; }
                .touchpad { display: grid; grid-template-columns: 1fr auto 1fr; grid-template-areas: "l . r" "cross middle face";
                            gap: 16px; align-items: center; width: min(#{Screen::WIDTH * scale}px, 96vw);
                            touch-action: none; user-select: none; -webkit-user-select: none; }
                .touchpad[hidden] { display: none; }
                .touchpad button { touch-action: none; padding: 0; min-width: 48px; min-height: 48px; font-size: 18px; }
                .pad-cross { grid-area: cross; display: grid; grid-template-areas: ". up ." "left . right" ". down .";
                             gap: 2px; justify-self: start; }
                .pad-middle { grid-area: middle; display: flex; gap: 8px; align-self: end; }
                .pad-middle button { min-height: 28px; font-size: 11px; padding: 0 8px; border-radius: 14px; }
                .pad-face { grid-area: face; display: grid; grid-template-areas: ". a" "b ."; gap: 8px; justify-self: end; }
                .pad-face button { width: 60px; height: 60px; border-radius: 50%; }
              </style>
            HTML
          end
        end
      end
    end
  end
end
