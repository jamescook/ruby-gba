# frozen_string_literal: true

module VBlank
  module Live
    # WHAT THE WINDOW KEEPS FOR A PLAYER, and the settings file it is kept in: the window's own
    # settings (WindowMenu::Settings, which the menu changes), which key and gamepad button is each
    # console button, and the keys the window keeps for itself (hotkeys). The rules are the desktop
    # build's, written again in Ruby from its runtime/rg_window.c — the same lines, the same
    # problems said in the same words, the same starting values — so one settings.txt serves the
    # desktop build and vblank run alike, and a change made in either is there in the other.
    #
    # The file is one `name = value` to a line, and `#` begins a note:
    #
    #   scale = 4
    #   volume = 60
    #   key.select = Backspace
    #   key.select = Right Shift
    #   pad.a = east
    #   hotkey.pause = P
    #
    # A key is named as SDL names it, "none" for no key. A line that cannot be used is said in
    # plain words, and the rest are used: a file never stops the window opening.
    #
    # Nothing here reads a file or knows SDL: the names of keys come from +key_names+, which SDL
    # gives the window (SDL::KeyNames) and a test gives a table, and SettingsFile reads and writes.
    class Settings
      # A console button: what a player calls it, its name in the file, the keys and the gamepad
      # button it starts on. The keys are mGBA's (SDL's scancodes: X, Z, Backspace and Right
      # Shift, Return, the arrows, S, A).
      Button = Data.define(:name, :setting, :keys, :pad)
      BUTTONS = Ractor.make_shareable([
        Button.new("A", :a, [27], :east), Button.new("B", :b, [29], :south),
        Button.new("Select", :select, [42, 229], :back), Button.new("Start", :start, [40], :start),
        Button.new("Right", :right, [79], :dpad_right), Button.new("Left", :left, [80], :dpad_left),
        Button.new("Up", :up, [82], :dpad_up), Button.new("Down", :down, [81], :dpad_down),
        Button.new("R", :r, [22], :right_shoulder), Button.new("L", :l, [4], :left_shoulder)
      ])

      # A key the window keeps for itself, and the key it starts on: P, N, F3, F11, M, F1, Tab.
      Hotkey = Data.define(:name, :setting, :key)
      HOTKEYS = Ractor.make_shareable([
        Hotkey.new("Pause", :pause, 19), Hotkey.new("Step one frame", :step, 17),
        Hotkey.new("Show frame rate", :frame_rate, 60), Hotkey.new("Fullscreen", :fullscreen, 68),
        Hotkey.new("Mute", :mute, 16), Hotkey.new("Show menu", :menu, 58), Hotkey.new("Fast forward", :fast_forward, 43)
      ])

      # A gamepad's buttons, in SDL's order: each one's place here is SDL's number for it.
      PAD_BUTTONS = %i[south east west north back guide start left_stick right_stick left_shoulder right_shoulder
                       dpad_up dpad_down dpad_left dpad_right].freeze

      KEYS_A_BUTTON = 2 # the most keys one button can have
      ESCAPE = 41 # gives up choosing a key, and so can be no button's or hotkey's
      LONGEST_LINE = 255
      FAST_SPEEDS = (2..8)
      FLAGS = { "fullscreen" => :fullscreen, "mute" => :muted, "frame_rate" => :frame_rate, "frame_time" => :frame_time }.freeze

      # The desktop build's starting values: the window's (WindowMenu::STARTING), and the frame
      # time, which its developer view shows, not shown.
      STARTING = Ractor.make_shareable(WindowMenu::STARTING.to_h.merge(frame_time: false))

      # The key +hotkey+ starts on.
      def self.starting_key(hotkey) = HOTKEYS.find { |each| each.setting == hotkey }.key

      # Which console button each of a gamepad's buttons is, by SDL's number for it, as the block
      # (given a console button, its gamepad button) says.
      def self.pad_map = BUTTONS.to_h { |button| [PAD_BUTTONS.index(yield(button.setting)), button.setting] }

      def initialize(key_names:)
        @key_names = key_names
        @now = STARTING.dup
        BUTTONS.each do |button|
          KEYS_A_BUTTON.times { |slot| @now[[:key, button.setting, slot]] = button.keys[slot] }
          @now[[:pad, button.setting]] = button.pad
        end
        HOTKEYS.each { |hotkey| @now[[:hotkey, hotkey.setting]] = hotkey.key }
        @owned = {} # the settings the file being written to holds for itself (#mark_inherited)
        @unwritten = false
      end

      # The window's own settings, as the menu shows and changes them.
      def window = WindowMenu::Settings.new(**@now.slice(*WindowMenu::Settings.members))

      # ...changed, as the menu changed them. A setting given the value it has is no change.
      def window=(settings)
        settings.to_h.each do |name, value|
          next if @now[name] == value

          @now[name] = value
          @owned[name] = true
          @unwritten = true
        end
      end

      # Which console button each of a gamepad's buttons is, by SDL's number for it.
      def pad_map = @pad_map ||= self.class.pad_map { |button| pad_of(button) }

      # The console buttons whose keys are down, as +down+ (given a scancode) says.
      def buttons_held(&down)
        BUTTONS.filter_map { |button| button.setting if keys_of(button.setting).any?(&down) }
      end

      # The keys a console button has, by scancode, and the gamepad button it is.
      def keys_of(button) = Array.new(KEYS_A_BUTTON) { |slot| @now[[:key, button, slot]] }.compact
      def pad_of(button) = @now[[:pad, button]]

      # The key a hotkey has, or nil.
      def hotkey_of(hotkey) = @now[[:hotkey, hotkey]]

      # The console button a key is, or the hotkey; nil for neither.
      def button_of_key(key) = key && BUTTONS.find { |button| keys_of(button.setting).include?(key) }&.setting
      def hotkey_of_key(key) = key && HOTKEYS.find { |hotkey| hotkey_of(hotkey.setting) == key }&.setting

      # Something has changed since the settings were last written.
      def unwritten? = @unwritten
      def mark_written = @unwritten = false

      # Every setting so far came from the file every game shares, and is not the own of the file
      # read next, a game's: that file keeps only what it says, and what changes while it plays.
      def mark_inherited = @owned.clear

      # THE SETTINGS AS TEXT for the file: every one, for the file every game shares, or with
      # +own_only+ only those the file being written to holds for itself, for a game's own.
      def text(own_only: false)
        all = !own_only
        lines = ["# The window's settings: one `name = value` to a line, and a line starting with # is a note.",
                 "# The window writes this file when something is changed in its menu, and reads it when it opens,",
                 "# so it can be edited by hand while the window is closed."]
        if own_only
          lines << "# This is one game's own file. It holds only what this game changes: every other setting comes"
          lines << "# from the file every game shares, so a change there still reaches this game."
        end
        lines << "scale = #{@now[:scale]}" if all || @owned[:scale]
        lines << "fullscreen = #{on_off(@now[:fullscreen])}" if all || @owned[:fullscreen]
        lines << "volume = #{@now[:volume]}" if all || @owned[:volume]
        lines << "mute = #{on_off(@now[:muted])}" if all || @owned[:muted]
        lines << "frame_rate = #{on_off(@now[:frame_rate])}" if all || @owned[:frame_rate]
        lines << "frame_time = #{on_off(@now[:frame_time])}" if all || @owned[:frame_time]
        lines << "fast_forward_speed = #{@now[:fast_forward_speed]}" if all || @owned[:fast_forward_speed]
        lines << "" << "# Keys, as SDL names them (Backspace, Right Shift, Left, X). A button has a line for each of its keys."
        BUTTONS.each do |button|
          next unless all || KEYS_A_BUTTON.times.any? { |slot| @owned[[:key, button.setting, slot]] }

          keys = keys_of(button.setting)
          lines.concat(keys.empty? ? ["key.#{button.setting} = none"] : keys.map { |key| "key.#{button.setting} = #{key_name(key)}" })
        end
        lines << "" << "# Gamepad buttons: south, east, west, north, back, guide, start, left_stick, right_stick,"
        lines << "# left_shoulder, right_shoulder, dpad_up, dpad_down, dpad_left, dpad_right."
        BUTTONS.each do |button|
          lines << "pad.#{button.setting} = #{pad_of(button.setting)}" if all || @owned[[:pad, button.setting]]
        end
        lines << "" << "# Keys the window keeps for itself. A console button cannot use one of them."
        HOTKEYS.each do |hotkey|
          lines << "hotkey.#{hotkey.setting} = #{key_name(hotkey_of(hotkey.setting))}" if all || @owned[[:hotkey, hotkey.setting]]
        end
        "#{lines.join("\n")}\n"
      end

      # READS SETTINGS TEXT over what is there now: each line it names a setting in replaces that
      # one and leaves the others, and that setting is now the file's own. Gives what could not be
      # used, a sentence each.
      def read(text)
        @problems = []
        @candidate = @now.dup
        @touched = {}
        # Bytes that are no letters are kept as question marks, so such a line is said and skipped.
        text.dup.force_encoding(Encoding::UTF_8).scrub("?").split("\n", -1).each_with_index do |raw, index|
          @line = index + 1
          next add_problem("that line is too long to be a setting, so it is left out.") if raw.bytesize > LONGEST_LINE

          line = raw.strip
          next if line.empty? || line.start_with?("#")
          next add_problem("\"#{line}\" is not `name = value`, so it is left out.") unless line.include?("=")

          name, value = line.split("=", 2).map(&:strip)
          read_line(name.downcase, value)
        end
        refuse_escape
        clear_clashing_keys
        @now = @candidate
        @pad_map = nil
        @problems
      end

      private

      def on_off(flag) = flag ? "on" : "off"

      def key_name(key)
        return "none" unless key

        given = @key_names.name(key)
        given.nil? || given.empty? ? "key #{key}" : given
      end

      # The key a name is, or nil for one that is not a key's. "key 4" is always understood.
      def key_named(name)
        return Regexp.last_match(1).to_i if name =~ /\Akey (\d+)\z/ && Regexp.last_match(1).to_i.positive?

        key = @key_names.key(name)
        key&.positive? ? key : nil
      end

      def add_problem(sentence) = @problems << "Line #{@line}: #{sentence}"

      def set_as_own(name, value)
        @candidate[name] = value
        @owned[name] = true
      end

      def read_line(name, value)
        case name
        when "scale" then read_number(:scale, value, WindowMenu::SCALES)
        when "volume" then read_number(:volume, value, 0..100)
        when "fast_forward_speed" then read_number(:fast_forward_speed, value, FAST_SPEEDS)
        when *FLAGS.keys then read_flag(name, value)
        when /\Akey\.(.*)\z/ then read_key(Regexp.last_match(1), value)
        when /\Apad\.(.*)\z/ then read_pad(Regexp.last_match(1), value)
        when /\Ahotkey\.(.*)\z/ then read_hotkey(Regexp.last_match(1), value)
        else add_problem("there is no setting called \"#{name}\", so the line is left out.")
        end
      end

      def read_number(setting, value, range)
        number = value.to_i if value.match?(/\A[+-]?\d+\z/)
        return set_as_own(setting, number) if number && range.cover?(number)

        add_problem("#{setting} is a whole number from #{range.min} to #{range.max}, not \"#{value}\".")
      end

      def read_flag(name, value)
        flag = on_or_off(value)
        return add_problem("#{name} is on or off, not \"#{value}\".") if flag.nil?

        set_as_own(FLAGS.fetch(name), flag)
      end

      # on/off in the ways a person writes them; nil for neither.
      def on_or_off(value)
        return true if %w[on yes true 1].include?(value.downcase)

        false if %w[off no false 0].include?(value.downcase)
      end

      def button_named(name) = BUTTONS.find { |button| button.setting.to_s.casecmp?(name) }

      def no_such_button(name)
        add_problem("there is no button called \"#{name}\" (they are #{BUTTONS.map(&:setting).join(', ')}).")
      end

      # The first line for a button replaces the keys it had; each after that adds one.
      def read_key(name, value)
        button = button_named(name) or return no_such_button(name)
        none = value.casecmp?("none")
        key = none ? nil : key_named(value)
        return add_problem("\"#{value}\" is not a key's name, so #{button.name} keeps the key it had.") if key.nil? && !none

        unless @touched[button.setting]
          KEYS_A_BUTTON.times { |slot| set_as_own([:key, button.setting, slot], nil) }
          @touched[button.setting] = true
        end
        return if key.nil?

        slot = KEYS_A_BUTTON.times.find { |at| @candidate[[:key, button.setting, at]].nil? }
        return add_problem("#{button.name} has room for #{KEYS_A_BUTTON} keys, so \"#{value}\" is left out.") unless slot

        set_as_own([:key, button.setting, slot], key)
      end

      def read_pad(name, value)
        button = button_named(name) or return no_such_button(name)
        pad = PAD_BUTTONS.find { |each| each.to_s.casecmp?(value) }
        return add_problem("\"#{value}\" is not a gamepad button the window knows, so #{button.name} keeps the one it had.") unless pad

        set_as_own([:pad, button.setting], pad)
      end

      def read_hotkey(name, value)
        hotkey = HOTKEYS.find { |each| each.setting.to_s.casecmp?(name) }
        return add_problem("there is no hotkey called \"#{name}\".") unless hotkey

        none = value.casecmp?("none")
        key = none ? nil : key_named(value)
        return add_problem("\"#{value}\" is not a key's name, so \"#{hotkey.name}\" keeps the key it had.") if key.nil? && !none

        set_as_own([:hotkey, hotkey.setting], key)
      end

      # Every key a button or a hotkey has, in the order a clash is settled in, with whose it is.
      def key_slots
        BUTTONS.flat_map { |button| Array.new(KEYS_A_BUTTON) { |slot| [[:key, button.setting, slot], button.name] } } +
          HOTKEYS.map { |hotkey| [[:hotkey, hotkey.setting], hotkey.name] }
      end

      def refuse_escape
        key_slots.each do |slot, owner|
          next unless @candidate[slot] == ESCAPE

          @problems << "Escape gives up choosing a key, so #{owner} cannot use it and has no key."
          set_as_own(slot, nil)
        end
      end

      # No key is two things: where two have one, the later loses it and it is said. Two keys of
      # the same button are the same thing said twice, and are not a clash.
      def clear_clashing_keys
        slots = key_slots
        slots.each_with_index do |(later, later_owner), at|
          key = @candidate[later] or next
          earlier, earlier_owner = slots.first(at).find { |slot, _| @candidate[slot] == key }
          next unless earlier

          unless later_owner == earlier_owner && later.first == :key
            @problems << "#{key_name(key)} is used for both #{earlier_owner} and #{later_owner}. It stays with " \
                         "#{earlier_owner} and is taken off #{later_owner}."
          end
          set_as_own(later, nil)
        end
      end
    end
  end
end
