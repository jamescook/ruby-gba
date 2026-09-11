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

        # One row of a menu: what it can say, whether it can be picked, the colours it
        # overrides, and what it does when it is chosen. `labels` is always a list,
        # because a settings row says a different thing depending on the setting, and
        # `showing` is the value that says which of them is on screen.
        Item = Data.define(:labels, :enabled, :color, :picked, :showing, :action)

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
          # A SETTINGS ROW SAYS A DIFFERENT THING depending on the setting, so give it the
          # list of things it can say and the variable that decides which:
          #
          #   m.item(["MUSIC: OFF", "MUSIC: ON"], showing: music) { music.set 1 - music }
          #
          # The words the value points at are the ones on screen, and they are part of the
          # row — so they light up with it, move with the cursor, and are what the block
          # under them changes. Written the other way round, as a label plus a separate
          # `draw_text` of the value beside it, the value would sit outside the row and
          # stay whatever colour it was drawn in.
          #
          # @param label [String, Array<String>] what the row says, or all it can say
          # @param enabled [Boolean] false for a row that is there but cannot be picked
          # @param color [Symbol, String, Integer, nil] this row's own unpicked colour
          # @param picked [Symbol, String, Integer, nil] this row's own picked colour
          # @param showing [Value, Symbol, nil] which of several labels is on screen
          def item(label, enabled: true, color: nil, picked: nil, showing: nil, &action)
            labels = words_of(label, showing)
            unless [true, false].include?(enabled)
              raise ArgumentError,
                    "`enabled:` says whether a row can be picked right now: true or false. " \
                    "Got #{enabled.inspect}."
            end

            @list << Item.new(labels: labels, enabled: enabled, color: color, picked: picked,
                              showing: showing, action: action)
            self
          end

          private

          # What the row can say, always as a list. One thing needs nothing to choose
          # between; several do, so a list without `showing:` is refused rather than
          # drawn all at once on top of itself.
          def words_of(label, showing)
            if label.is_a?(String)
              return [label] if showing.nil?

              raise ArgumentError,
                    "A menu row that says one thing does not need `showing:`. Give the row " \
                    "the list of things it can say, like [\"MUSIC: OFF\", \"MUSIC: ON\"]. " \
                    "Or drop `showing:`."
            end
            unless label.is_a?(Array) && label.length >= 2 && label.all?(String)
              raise ArgumentError,
                    "A menu row needs its words as a String. A row that changes needs two or " \
                    "more Strings in a list. Got #{label.inspect}."
            end
            return label if showing

            raise ArgumentError,
                  "This menu row can say #{label.length} things, so it needs `showing:` to " \
                  "say which one is on screen. Give it the variable that decides, like " \
                  "`showing: music`."
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

          # True on the frame the pick moved — for a sound, or a preview that reloads.
          #
          #   menu.moved.then { beep :blip }
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
        # menu written above the loop would run one time and then never again. That rule
        # is the same on both screens, which is the whole point of it being a verb: the
        # menu owns its own drawing, so nothing about where it goes changes with the
        # screen the way a bare `draw_text` does.
        #
        # WHAT IT COSTS DEPENDS ON THE SCREEN, and it is worth knowing before you write a
        # long one. On `screen :bitmap` the rows are painted into the picture, so they
        # cost drawing time and no sprites. On `screen :tiled` the console composites the
        # text for you, and every character is one little sprite of its own — out of the
        # same table of 128 the game's own sprites come from. So reckon about ONE sprite
        # for each character of a label, and none at all for a space. Eight rows of ten
        # characters is about 72; twelve rows of twelve does not fit, and says so.
        #
        # A row lights up by CHANGING COLOUR rather than by being drawn twice, which is
        # what keeps that number at one and not two — see draw_text's `showing:`. The
        # cursor is the only per-row extra, because it is shown or not shown rather than
        # recoloured.
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
          # The rows are the verb's own text, not text the author placed, so the rule
          # about where an author writes draw_text does not reach them (see
          # Builder::Text#verb_owns_its_text). That is what lets one menu verb work the
          # same way on a screen you paint and on a screen the console composes.
          spent = menu_sprites_spent do
            verb_owns_its_text(:menu) do
              menu_draw(items, pick, x: x, y: y, step: step, font: font, color: color,
                                     picked: picked, disabled: disabled, cursor: cursor)
            end
          end
          menu_fits_the_sprite_table!(name, spent)
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
          PLAIN_NAME = "a menu with no frames to run on"

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

        # How a menu draws: where its column is, the three colours, the cursor and the
        # font. Carried as one thing so the drawing below reads as drawing rather than as
        # an argument list threaded through it.
        Style = Data.define(:x, :cursor_x, :font, :color, :picked, :disabled, :cursor)

        # Draw the rows. A row that cannot be picked is drawn dim and never any other
        # way, so its test is settled at build time and costs nothing at run time.
        def menu_draw(items, pick, x:, y:, step:, font:, color:, picked:, disabled:, cursor:)
          # The cursor hangs one space off the left of the labels, so the column of
          # labels stays a straight edge whichever row the cursor is on.
          style = Style.new(x: x, cursor_x: x - text_width("#{cursor} ", font: font),
                            font: font, color: color, picked: picked, disabled: disabled,
                            cursor: cursor)

          items.each_with_index do |item, i|
            row = y + (i * step)
            item.labels.each_with_index do |words, nth|
              draw = -> { menu_draw_row(item, words: words, row: row, style: style, picked_when: -> { pick == i }) }
              # A row that says one thing draws it. A row that can say several draws each
              # of them under a test, so the one the game's own value points at is the one
              # on screen and the others are simply not drawn.
              next draw.call if item.labels.length == 1

              (item.showing == nth).then { draw.call }
            end
          end
        end

        # One row, in whichever of its three colours applies. `picked_when` is a block
        # rather than a test because a test belongs to one place in the tree, and a row
        # that can say several things asks the same question once for each of them.
        #
        # The words are ONE draw in a pair of colours rather than two draws under a test.
        # It says the same thing and paints the same pixels; what it saves is on a tiled
        # screen, where two draws would be two sprites for every character with one of
        # them always hidden. The cursor is still a test, because it is shown or not
        # shown rather than recoloured.
        def menu_draw_row(item, words:, row:, style:, picked_when:)
          unless item.enabled
            draw_text words, style.x, row, style.disabled, font: style.font
            return
          end

          bright = item.picked || style.picked
          draw_text words, style.x, row, [item.color || style.color, bright],
                    font: style.font, showing: picked_when.call
          return if style.cursor.empty?

          picked_when.call.then do
            draw_text style.cursor, style.cursor_x, row, bright, font: style.font
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
          unless items.any?(&:enabled)
            raise ArgumentError,
                  "Every row of menu :#{name} is `enabled: false`, so the cursor has nowhere " \
                  "to go. To fix this, remove `enabled: false` from one row."
          end

          items.map { |item| item.showing ? item.with(showing: menu_deciding_value!(item)) : item }
        end

        # The value that says which of a row's several labels is on screen. A Symbol names
        # a variable, the way a Symbol does everywhere else in the DSL.
        def menu_deciding_value!(item)
          showing = item.showing
          return handle_for(showing) if showing.is_a?(Symbol)
          return showing if showing.is_a?(Value)

          raise ArgumentError,
                "`showing:` takes the variable that says which words the row shows. Give a " \
                "variable, like `showing: music` or `showing: :music`. Got #{showing.inspect}."
        end

        # How many sprite slots the block's drawing took. Zero on a bitmap screen, where
        # text is painted into the picture; on a tiled screen every character the console
        # composites is one little sprite of its own, and they come out of the same table
        # the game's own sprites do.
        def menu_sprites_spent
          before = @hud_objects.length
          yield
          @hud_objects.length - before
        end

        # A tiled menu that cannot fit in the sprite table.
        #
        # Only the menu's own share is checked here, because that is the part the menu can
        # say something useful about — a game that overspends across everything it draws is
        # a bigger question than this verb. Caught at the call site, where the labels are,
        # rather than at lowering, where the message could only count anonymous sprites.
        def menu_fits_the_sprite_table!(name, spent)
          return if spent <= Constants::MAX_SPRITES

          raise ArgumentError,
                "menu :#{name} needs #{spent} sprites for its rows, and the console draws at " \
                "most #{Constants::MAX_SPRITES} at once. On a tiled screen the console draws " \
                "each character as its own little sprite. To fix this, use shorter labels or " \
                "fewer rows. Or put the menu on a `screen :bitmap`, where text costs no " \
                "sprites at all."
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
