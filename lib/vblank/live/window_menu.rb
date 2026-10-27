# frozen_string_literal: true

module VBlank
  module Live
    # THE MENU OVER THE WINDOW A GAME IS PLAYED IN, written down once: what it holds, the keys and
    # gamepad buttons that work it, and how it looks. vblank run draws it (Menu says how it
    # behaves, SDL draws it), and the desktop build and the web page are to draw this same menu
    # from it, each in its own language, so a line added here becomes a line in each. Cartridges
    # have none.
    #
    # It looks like Dear ImGui's dark menu bar, as the desktop build first had it: a bar along the
    # top with a heading for each part, the open heading's lines in a box under it, a slider for a
    # number and a check mark for a setting that is on. It is drawn over the game's picture in the
    # window's own pixels, not the game's, so its letters are sharp on any screen.
    module WindowMenu
      # What the window does, as a player last left it. The starting values are the desktop build's
      # (rg_window.c), the frame rate shown among them.
      Settings = Data.define(:fast_forward_speed, :scale, :fullscreen, :volume, :muted, :frame_rate)
      STARTING = Settings.new(fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false,
                              frame_rate: true)

      # A heading on the bar and the lines under it.
      Heading = Data.define(:name, :lines)

      # A line under a heading: its +label+, and what it is.
      # - :action does what +does+ names (:resume, :quit) when it is chosen with Enter.
      # - :slider holds a number of +setting+'s within +range+, changed +step+ at a time with left
      #   and right, and written as +written+ says: :times ("4x"), :percent ("90%"), or :window
      #   ("3x  (720 × 480)", the size the window is then).
      # - :check holds +setting+ on or off, switched with Enter.
      # +shortcut+ is the key that does the same outside the menu, written dim at the right.
      # +line_before+ draws a line across the box above it, to set it apart.
      Line = Data.define(:label, :kind, :does, :setting, :range, :step, :written, :shortcut, :line_before) do
        def self.action(label, does, shortcut: nil, line_before: false)
          new(label, :action, does, nil, nil, nil, nil, shortcut, line_before)
        end

        def self.slider(label, setting, range, step, written)
          new(label, :slider, nil, setting, range, step, written, nil, false)
        end

        def self.check(label, setting, shortcut: nil) = new(label, :check, nil, setting, nil, nil, nil, shortcut, false)
      end

      # The most times the picture's size a window can be made. A frontend may say fewer: the most
      # that fits on the screen it is on.
      SCALES = (1..10)

      HEADINGS = Ractor.make_shareable([
        Heading.new("Game", [Line.action("Resume", :resume, shortcut: "F1"),
                             Line.slider("Fast forward", :fast_forward_speed, 2..8, 1, :times),
                             Line.action("Quit", :quit, shortcut: "Esc", line_before: true)]),
        Heading.new("Window", [Line.slider("Size", :scale, SCALES, 1, :window), Line.check("Fullscreen", :fullscreen),
                               Line.check("Show frame rate", :frame_rate)]),
        Heading.new("Sound", [Line.slider("Volume", :volume, 0..100, 10, :percent), Line.check("Mute", :muted)])
      ])

      # THE KEYS, by name; each frontend knows which of its own keys and buttons each name is. F1
      # opens and closes the menu, as in the desktop build, and so does the key above Tab, which a
      # Mac keyboard can press without holding fn. On a gamepad, the guide button in the middle
      # does, or Back and Start pressed together (a Mac may keep the guide button for its own use).
      # The arrows or the D-pad move; Enter or the gamepad's A does what a line says; the gamepad's
      # B closes the menu.
      OPEN_KEYS = %i[f1 grave].freeze
      OPEN_PAD = %i[guide].freeze
      OPEN_PAD_TOGETHER = %i[back start].freeze
      MOVE_KEYS = { up: :up, down: :down, left: :left, right: :right, enter: :enter }.freeze
      MOVE_PAD = { dpad_up: :up, dpad_down: :down, dpad_left: :left, dpad_right: :right, a: :enter, b: :close }.freeze

      # THE LOOK: sizes in points, which a frontend makes pixels by the screen's density, and colours
      # as red, green, blue and opacity, 0 to 255 each. Dear ImGui's dark colours.
      SIZES = Ractor.make_shareable(
        { bar: 22, row: 22, pad: 8, heading_gap: 14, heading_pad: 4, least_width: 200, label_gap: 30, slider: 140,
          grab: 10, check: 14, corner: 4, frame_corner: 3, line_before: 9, status_gap: 8, status_pad: 8, status_line: 19 }
      )
      COLORS = Ractor.make_shareable(
        { text: [255, 255, 255, 255], dim: [128, 128, 128, 255], bar: [36, 36, 36, 255], box: [20, 20, 20, 240],
          border: [110, 110, 128, 128], chosen: [66, 150, 250, 204], open: [66, 150, 250, 79],
          frame: [41, 74, 122, 138], grab: [61, 133, 224, 255], status: [15, 15, 15, 140],
          paused: [255, 204, 77, 255], fast: [128, 230, 255, 255] }
      )

      # WHAT A FRONTEND DRAWS, in the window's own pixels, from the top left: boxes with round
      # corners of +radius+, and words, each letter copied from the font's picture
      # (Graphics::MenuFont) as +letters+ says, in +color+.
      Box = Data.define(:x, :y, :width, :height, :radius, :color)
      Words = Data.define(:text, :color, :letters)
    end
  end
end
