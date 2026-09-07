# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # A menu: a list of things to pick from, a selector that moves, and what each one
      # does. Nearly every game has one — a title screen, a pause screen, a shop, a
      # jukebox — and until now this framework had no word for it.
      #
      # WHAT A GAME WROTE INSTEAD, and it is the same thirty lines every time: a variable
      # holding which row is picked, two button tests that add and subtract with the
      # wrapping done by hand, a pass that draws every row in the dull colour, a second
      # pass that redraws the picked one in the bright colour, a cursor drawn beside it,
      # and a test for the button that acts. That is a lot of bookkeeping around three
      # lines of intent, and every game gets a slightly different bit of it wrong.
      #
      # SAID ONCE, a menu is: an ordered list of items, one of them picked, up and down
      # moving the pick and wrapping at both ends, and a button running the picked item's
      # block. Everything else — which colour is which, what the cursor looks like, how
      # far apart the rows are — is decoration the game SAYS rather than builds.
      #
      # This is a pack, so every line below is written in public DSL verbs — `var`,
      # `held`, `pressed`, `.then`, `draw_text`. Nothing here is new capability, which is
      # exactly why it is a pack and not part of the library proper (see {Effects}).
      module Menus
        # How long a held button waits before it walks to the next row. Copied from
        # Wolfenstein 3D, which waits 20 tics: a tap always moves exactly one row, and
        # holding walks at about three rows a second — fast enough to feel responsive,
        # slow enough that you can stop where you meant to.
        HELD_REPEAT_FRAMES = 20

        # What is drawn beside the row the cursor is on.
        CURSOR = ">"

        # A row that cannot be picked. Dim enough to read as "not for you now", light
        # enough to still be readable — the point of a greyed row is that you can see
        # what you are missing.
        DISABLED_COLOR = "#404040"

        # The gap between the bottom of one row and the top of the next, when the game
        # does not say. With the built-in 7px font that puts rows 13 pixels apart, which
        # is what Wolfenstein's menus use.
        ROW_GAP = 6

        # One row of a menu: what it says, whether it can be picked, the colours it
        # overrides, and what it does when it is chosen.
        Item = Data.define(:label, :enabled, :color, :picked, :action)

        # Collects the rows of one menu. Handed to the `menu` block as its argument
        # rather than being the block's `self`, so a bare DSL verb written inside an
        # item's own block still reaches the build it was written in — including in a
        # game split across files, where `self` is a plain Ruby object of the game's own.
        class Items
          attr_reader :list

          def initialize
            @list = []
          end

          # Add one row.
          #
          #   m.item("NEW GAME")                  { state.set PLAYING }
          #   m.item("LOAD GAME", enabled: false) { }
          #   m.item("ODE TO JOY", picked: :yellow)
          #
          # @param label [String] what the row says
          # @param enabled [Boolean] false for a row that is there but cannot be picked
          # @param color [Symbol, String, Integer, nil] this row's own unpicked colour
          # @param picked [Symbol, String, Integer, nil] this row's own picked colour
          def item(label, enabled: true, color: nil, picked: nil, &action)
            unless label.is_a?(String)
              raise ArgumentError, "A menu row needs its words as a String. Got #{label.inspect}."
            end
            unless [true, false].include?(enabled)
              raise ArgumentError,
                    "`enabled:` says whether a row can be picked right now: true or false. " \
                    "Got #{enabled.inspect}."
            end

            @list << Item.new(label: label, enabled: enabled, color: color, picked: picked,
                              action: action)
            self
          end
        end

        # A menu the game can read back: which row is picked, and whether it just moved.
        class Menu
          def initialize(picked, moved, length)
            @picked = picked
            @moved = moved
            @length = length
          end

          # How many rows it has (a build-time number).
          attr_reader :length

          # Which row the cursor is on, counting from 0 — a {Value}, so a game can read
          # it, compare it, and draw from it. It is an ordinary variable underneath, so
          # setting it jumps the cursor.
          attr_reader :picked

          # True on the frame the pick moved — for a sound, a preview that reloads, a
          # tune that starts over.
          #
          #   menu.moved.then { stop_music }
          def moved
            @moved == 1
          end
        end

        # Declare a menu: a list of rows, a cursor that moves between them, and a block
        # per row saying what picking it does.
        #
        #   menu :main, at: [80, 60] do |m|
        #     m.item("NEW GAME")                  { state.set PLAYING }
        #     m.item("LOAD GAME", enabled: false) { state.set LOADING }
        #     m.item("SOUND")                     { state.set SOUND }
        #   end
        #
        # Up and down move the cursor and WRAP at both ends. A row that cannot be picked
        # is stepped over rather than landed on, and is drawn in its own dim colour.
        # Holding a button walks the list instead of moving one row and stopping. The
        # button named by `press:` runs the picked row's block.
        #
        # Call it where your frame's work goes — inside your `game_loop`, or inside a
        # `scene`. A menu reads the buttons and draws itself again on every frame, so a
        # menu written above the loop would run one time and then never again.
        #
        # WHICH ROW IS PICKED SURVIVES leaving and coming back, so a submenu you back out
        # of opens where you left it. That is free: the pick is a variable, and a
        # variable's starting value is applied once, at power-on.
        #
        # THE COLOURS come in three, and any of them can be said per row:
        #
        #   color:     a row the cursor is not on
        #   picked:    the row the cursor is on
        #   disabled:  a row that cannot be picked
        #
        # @param name [Symbol] a name for this menu, so two menus keep their own pick
        # @param at [Array(Integer, Integer)] where the first row's label starts
        # @param spacing [Integer, nil] pixels from one row to the next
        # @param color [Symbol, String, Integer] an unpicked row
        # @param picked [Symbol, String, Integer] the picked row
        # @param disabled [Symbol, String, Integer] a row that cannot be picked
        # @param cursor [String] drawn to the left of the picked row ("" for none)
        # @param font [Symbol] a font registered by {Builder::Text#font}
        # @param press [Symbol] the button that runs the picked row's block
        # @param repeat_every [Integer] frames between rows while a button is held
        # @return [Menu] a handle: `.picked`, `.moved`, `.length`
        def menu(name, at:, spacing: nil, color: :gray, picked: :white,
                 disabled: DISABLED_COLOR, cursor: CURSOR, font: :default,
                 press: :a, repeat_every: HELD_REPEAT_FRAMES, &block)
          items = menu_items!(name, block)
          menu_screen!
          menu_place!
          check_button!(press)
          x, y = menu_origin!(at)
          step = menu_spacing!(spacing || (text_height(font: font) + ROW_GAP))
          menu_repeat!(repeat_every)

          pick = var :"__menu_#{name}", items.index(&:enabled)
          wait = var :"__menu_#{name}_wait", 0
          moved = var :"__menu_#{name}_moved", 0

          menu_move(items, pick, wait, moved, repeat_every)
          menu_choose(items, pick, press)
          menu_draw(items, pick, x: x, y: y, step: step, font: font,
                                 color: color, picked: picked, disabled: disabled, cursor: cursor)
          Menu.new(pick, moved, items.length)
        end

        # The guardrail this pack brings with it — the same footgun the other effects
        # have, for the same reason, so it reads the same way.
        def self.checks
          @checks ||= [NeedsGameLoop.new]
        end

        # A menu with no frames to happen on.
        #
        # A menu is a button read and a redraw made on every frame, so it only exists
        # over time. With no game loop there are no frames: the rows are drawn once, the
        # cursor never moves, and no button does anything.
        class NeedsGameLoop
          NAME = :menu_needs_game_loop

          MESSAGE =
            "This game declares a menu, but it has no `game_loop`. A menu reads the " \
            "buttons and draws itself again on every frame, so it needs frames to run " \
            "on. With no game loop there are none: the rows are drawn one time, and the " \
            "cursor never moves. To fix this, put the game in a `game_loop`."

          # Every menu's pick variable is named for the menu it belongs to.
          PICK_PREFIX = "__menu_"

          def detect(program)
            pick = menu_pick(program)
            return [] if pick.nil? || paced?(program)

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: pick)]
          end

          private

          def menu_pick(program)
            program.each.find { |node| node.kind == :set && node.var.to_s.start_with?(PICK_PREFIX) }
          end

          def paced?(program)
            program.each.any? { |node| node.kind == :loop }
          end
        end

        private

        # Move the cursor. A tap moves exactly one row; holding waits and then walks,
        # which is the whole of "held-button repeat" — the wait is cleared the moment
        # neither button is down, so the next tap moves at once however long you held
        # the last one.
        def menu_move(items, pick, wait, moved, repeat_every)
          moved.set 0
          (held(:up) | held(:down)).then do
            (wait == 0).then do
              wait.set repeat_every
              moved.set 1
              held(:down).then { menu_step(items, pick, 1) }
                         .else { menu_step(items, pick, -1) }
            end.else { wait.sub 1 }
          end.else { wait.set 0 }
        end

        # One step of the cursor, wrapping at the end it walked off.
        #
        # A row that cannot be picked is stepped OVER rather than landed on. Which rows
        # those are is settled as the program is built, so each one costs a single test:
        # land on it, and go straight on to the next row that can be picked. A menu with
        # nothing disabled emits none of these tests at all.
        def menu_step(items, pick, direction)
          last = items.length - 1
          if direction.positive?
            pick.add 1
            (pick > last).then { pick.set 0 }
          else
            pick.sub 1
            (pick < 0).then { pick.set last }
          end

          items.each_index do |i|
            next if items[i].enabled

            (pick == i).then { pick.set menu_next_pickable(items, i, direction) }
          end
        end

        # The next row that can be picked, walking from +from+ in +direction+ and
        # wrapping. Worked out here, as the program is built, so nothing walks at run
        # time. There is always one: a menu where no row can be picked is refused.
        def menu_next_pickable(items, from, direction)
          count = items.length
          1.upto(count) do |offset|
            at = (from + (direction * offset)) % count
            return at if items[at].enabled
          end
        end

        # Run the picked row's block when the button is pressed. On the press edge, so
        # holding the button down chooses once rather than once a frame.
        def menu_choose(items, pick, press)
          return if items.none?(&:action)

          pressed(press).then do
            items.each_with_index do |item, i|
              next unless item.action

              # `.call` rather than instance_exec: the block keeps the `self` it was
              # written with, so a game split across files still sees its own object.
              (pick == i).then { item.action.call }
            end
          end
        end

        # Draw the rows. A row that cannot be picked is drawn dim and never any other
        # way, so its test is settled at build time and costs nothing at run time.
        def menu_draw(items, pick, x:, y:, step:, font:, color:, picked:, disabled:, cursor:)
          # The cursor hangs one space off the left of the labels, so the column of
          # labels stays a straight edge whichever row the cursor is on.
          cursor_x = x - text_width("#{cursor} ", font: font)

          items.each_with_index do |item, i|
            row = y + (i * step)
            unless item.enabled
              draw_text item.label, x, row, disabled, font: font
              next
            end

            bright = item.picked || picked
            (pick == i).then do
              draw_text cursor, cursor_x, row, bright, font: font unless cursor.empty?
              draw_text item.label, x, row, bright, font: font
            end.else do
              draw_text item.label, x, row, item.color || color, font: font
            end
          end
        end

        # Collect the rows, and refuse a menu that cannot work. All of these are wrong
        # the moment they are typed, so they are raised here rather than in a guardrail.
        def menu_items!(name, block)
          unless block
            raise ArgumentError,
                  "menu :#{name} needs its rows: menu :#{name}, at: [x, y] do |m| " \
                  "m.item(\"NEW GAME\") { ... } end."
          end

          collected = Items.new
          run_block(collected, &block)
          items = collected.list
          if items.empty?
            raise ArgumentError,
                  "menu :#{name} has no rows. Add one with `m.item(\"NEW GAME\") { ... }`."
          end
          return items if items.any?(&:enabled)

          raise ArgumentError,
                "Every row of menu :#{name} is `enabled: false`, so the cursor has nowhere " \
                "to go. To fix this, remove `enabled: false` from one row."
        end

        # A menu draws with `draw_text`, and on a tiled screen the console draws the text
        # for you from a list settled once at build time. So the same call cannot both
        # read the buttons every frame and declare its rows once. Say so plainly rather
        # than let the rows appear and the cursor sit still.
        def menu_screen!
          return unless Builder::Text::TILE_HARDWARE_MODES.include?(@screen_mode)

          raise ArgumentError,
                "menu needs a `screen :bitmap`. On a tiled screen the console draws the text " \
                "for you, from a list it settles one time. A menu cannot redraw its rows as " \
                "the cursor moves there. To fix this, put the menu on a bitmap screen."
        end

        # A menu is per-frame work, so it belongs where the frame's work goes.
        def menu_place!
          return if @building_scene || @container_stack.length > 1

          raise ArgumentError,
                "Call menu inside your game_loop, or inside a scene. A menu reads the " \
                "buttons and draws its rows again on every frame. A menu above the loop " \
                "runs one time, at the start, and then never again."
        end

        def menu_origin!(at)
          unless at.is_a?(Array) && at.length == 2 && at.all?(Integer)
            raise ArgumentError,
                  "menu takes `at:` as where the first row starts, like `at: [80, 60]`. " \
                  "Got #{at.inspect}. To centre a column of rows, ask the font how wide " \
                  "the widest one comes out with `text_width`."
          end

          at
        end

        def menu_spacing!(step)
          return step if step.is_a?(Integer) && step.positive?

          raise ArgumentError,
                "menu takes `spacing:` as the pixels from one row to the next. " \
                "Got #{step.inspect}."
        end

        def menu_repeat!(frames)
          return if frames.is_a?(Integer) && frames.positive?

          raise ArgumentError,
                "menu takes `repeat_every:` as the frames a held button waits before it " \
                "walks to the next row. Got #{frames.inspect}."
        end
      end
    end
  end
end
