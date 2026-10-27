# frozen_string_literal: true

module VBlank
  module Live
    # THE MENU OVER THE WINDOW a game is played in, as the desktop build has: the window's own
    # settings, a line each, one of them chosen. Up and down choose a line, going round at either
    # end; left and right change what it holds, never past what it can be; Enter switches a
    # setting on or off, or does what the line says. The game is held while the menu is open (the
    # window sees to that), and the window draws #lines over the picture and does what #settings
    # say. Nothing here knows about a window, so it is played in tests with none.
    class Menu
      # What the window does, as a player last left it. The starting values are the desktop
      # build's.
      Settings = Data.define(:fast_forward_speed, :scale, :fullscreen, :volume, :muted, :frame_rate)

      # A line that holds a number: its words, the setting, how far it can go, the step, and the
      # word after the number.
      Number = Data.define(:label, :setting, :range, :step, :unit)
      # A line that holds on or off.
      Switch = Data.define(:label, :setting)
      # A line that does something: Resume or Quit.
      Action = Data.define(:label, :action)

      # The sizes the window can be made, in times the picture's own.
      SCALES = (1..6)

      LINES = [
        Action.new("Resume", :resume),
        Number.new("Fast forward", :fast_forward_speed, 2..8, 1, "x"),
        Number.new("Window size", :scale, SCALES, 1, "x"),
        Switch.new("Fullscreen", :fullscreen),
        Number.new("Volume", :volume, 0..100, 10, ""),
        Switch.new("Mute", :muted),
        Switch.new("Frame rate", :frame_rate),
        Action.new("Quit", :quit)
      ].freeze

      # The widest a line's words and value are, so every value lines up at its right: with the
      # mark before it, a line is 18 letters, and the window's letters are 8 of the console's
      # pixels wide, so the menu fits the Color's 160-pixel screen as well as the Advance's.
      WIDTH = 16

      attr_reader :settings

      def initialize(fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false, frame_rate: false)
        @settings = Settings.new(fast_forward_speed: fast_forward_speed, scale: scale, fullscreen: fullscreen,
                                 volume: volume, muted: muted, frame_rate: frame_rate)
        @open = @quit = false
        @chosen = 0
      end

      def open? = @open

      # Quit was chosen.
      def quit? = @quit

      # Opens the menu, on Resume, or closes it.
      def toggle
        @open = !@open
        @chosen = 0
      end

      # One of :up, :down, :left, :right or :enter, pressed while the menu is open.
      def press(key)
        line = LINES[@chosen]
        case key
        when :up then @chosen = (@chosen - 1) % LINES.size
        when :down then @chosen = (@chosen + 1) % LINES.size
        when :left, :right then step(line, key == :right ? 1 : -1) if line.is_a?(Number)
        when :enter then enter(line)
        end
      end

      # Each line as words, the chosen one marked: "> Window size   3x".
      def lines
        LINES.each_with_index.map do |line, index|
          mark = index == @chosen ? "> " : "  "
          value = value_words(line)
          mark + (value ? line.label + value.rjust(WIDTH - line.label.length) : line.label)
        end
      end

      private

      def step(line, direction)
        now = @settings.public_send(line.setting)
        @settings = @settings.with(line.setting => (now + (direction * line.step)).clamp(line.range))
      end

      def enter(line)
        case line
        when Switch then @settings = @settings.with(line.setting => !@settings.public_send(line.setting))
        when Action
          @open = false if line.action == :resume
          @quit = true if line.action == :quit
        end
      end

      def value_words(line)
        case line
        when Number then "#{@settings.public_send(line.setting)}#{line.unit}"
        when Switch then @settings.public_send(line.setting) ? "on" : "off"
        end
      end
    end
  end
end
