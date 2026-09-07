# frozen_string_literal: true

module Wolf3D
  # EVERYTHING YOU MEET BEFORE YOU PLAY: the rating box, the title screen, the credits, the
  # main menu, the episode list, the difficulty screen — and the pause menu, which is the main
  # menu again with two of its rows saying something else.
  #
  # THE ATTRACT LOOP IS THE PART A PLAYER MEETS FIRST and the part nothing else in this game
  # does. Left alone at the boot screen the original cycles through its still screens for ever,
  # and ANY button at any point drops you into the menu. That is the only way in — there is no
  # "press start" anywhere in Wolfenstein.
  #
  # WHAT IS THINNER THAN THE ORIGINAL, and it is worth saying rather than discovering: the
  # original's loop plays a RECORDED DEMO between the still screens, which means replaying a
  # tape of somebody's input frame by frame. There is no such tape here and no machinery to
  # play one, so the loop is the still screens alone. That is the one place this is plainly
  # less than the game it came from.
  #
  # A MENU IS A SCENE and the game is another, which is the whole shape of this file. A scene
  # is a named state that runs once a frame while it is the one you are in, so "which screen am
  # I on" is a variable and "what does this screen do" is a scene — and the game itself is one
  # of them, no different from the menu in front of it.
  #
  # WHAT THE ORIGINAL DOES THAT THIS DOES NOT, both deliberate and both small: the gun does not
  # slide half a step with a sound at each end when you move (it jumps), and picking a row does
  # not play a shot. The blink is here, because the blink is what makes the selector read as a
  # gun rather than an arrow.
  class Menus
    # WHICH SCREEN YOU ARE ON, in the order you meet them. The game is the last of them, which
    # is the point: it is a screen like the others.
    NOTICE = 0      # the rating box, shown once at boot
    TITLE = 1       # the title screen
    CREDITS = 2     # who made it
    MENU = 3        # the main menu, which is also the pause menu
    EPISODES = 4
    DIFFICULTY = 5
    PLAYING = 6

    ACROSS = FirstPerson::ACROSS
    DOWN = FirstPerson::DOWN

    # HOW LONG EACH STILL SCREEN HOLDS, in frames. The original counts in seconds and so does
    # this: fifteen on the title, ten on the credits. The rating box is the one that differs —
    # the original waits for a key and would sit there all day, which is not what a handheld
    # left on the sofa should do.
    SECOND = 60
    NOTICE_FRAMES = 5 * SECOND
    TITLE_FRAMES = 15 * SECOND
    CREDITS_FRAMES = 10 * SECOND

    # THE SELECTOR BLINKS rather than sitting still: the gun for a second, then the same gun
    # with its muzzle flashing for about a ninth of one. A steady cursor is the wrong look.
    BLINK_ON = SECOND
    BLINK_OFF = 7

    # HOW LONG A HELD BUTTON WAITS before it walks to the next row. The original's TicDelay(20)
    # is twenty of its seventy-a-second tics, so a fifth of a second either way.
    HELD_REPEAT = 17

    # THE MENU'S OWN COLOURS, out of Wolfenstein's 256 and out of the original's own header
    # (wl_menu.h) rather than matched by eye.
    BACKGROUND = 0x2d
    STRIPE = 0x2c
    BORDER = 0x29
    BORDER_SHADOW = 0x23
    TEXT = 0x17
    HIGHLIGHT = 0x13
    DISABLED = 0x2b

    # WHAT A MENU FADES TO WHEN YOU PICK A ROW, and it is not black: the original leaves every
    # menu on VL_FadeOut(0,255,43,0,0,10), which is ten steps to a dark RED. (Spear of Destiny
    # fades to blue.) Written as the channels the original writes, out of the 63 a VGA channel
    # held, so the number beside it is the one in the source.
    FADE_CHANNELS = [43, 0, 0].freeze
    FADE_FRAMES = 10

    # THE TWO ALPHABETS, as the release stores them: the small one is the menu's face and the
    # big one is what a heading is set in.
    LETTERING = :wolf_menu
    HEADING = :wolf_heading

    # ROWS ARE 13 PIXELS APART, which is the original's spacing and happens to be the small
    # alphabet's own height plus three.
    ROW_STEP = 13

    # The gun hangs off the left of the column of rows, with a gap between.
    GUN_GAP = 6

    # Where the main menu's heading plate goes, and the band of stripes behind it: a black bar
    # with a coloured rule along the bottom of it, which is what the plate sits on.
    STRIPE_Y = 8
    STRIPE_H = 24
    STRIPE_RULE = 22

    # Where a heading of lettering sits, and the space left under any heading before the rows
    # begin. The main menu's heading is a picture and the other two are a line of lettering; a
    # screen's rows are then centred in whatever is left below, so no screen carries a row
    # position of its own.
    HEADING_Y = 10
    HEADING_GAP = 8

    # How far outside the rows the main menu's bevelled window is drawn.
    WINDOW_PAD_X = 8
    WINDOW_PAD_Y = 6

    # WHAT THE MAIN MENU SAYS, and two of its four rows say something else once a game is on —
    # which is exactly what the original does with its pause menu. It does not open a second
    # menu; the same list changes what two of its rows mean, in place.
    NEW_GAME = ["NEW GAME", "END GAME"].freeze
    LOAD_GAME = "LOAD GAME"
    SOUND = ["SOUND: OFF", "SOUND: ON"].freeze
    BACK = ["BACK TO DEMO", "BACK TO GAME"].freeze

    # THE FOUR ANSWERS TO "HOW TOUGH ARE YOU?", in the order the original asks them, each with
    # the portrait of BJ that goes beside it.
    DIFFICULTIES = [
      ["Can I play, Daddy?", :difficulty_baby],
      ["Don't hurt me.", :difficulty_easy],
      ["Bring 'em on!", :difficulty_normal],
      ["I am Death incarnate!", :difficulty_hard]
    ].freeze
    NORMAL = 2

    HOW_TOUGH = "How tough are you?"
    WHICH_EPISODE = "Which episode to play?"

    # THE SIX EPISODES BY NAME. A cartridge holds the floors it was built with, so a row is
    # only pickable when this one really carries that episode's first floor.
    EPISODE_NAMES = [
      "Escape from Wolfenstein",
      "Operation: Eisenfaust",
      "Die, Fuhrer, Die!",
      "A Dark Secret",
      "Trail of the Madman",
      "Confrontation"
    ].freeze

    # THE SCREENS BY NAME, so a cartridge can be built to boot on one of them. See +starting_on+.
    BY_NAME = { "notice" => NOTICE, "title" => TITLE, "credits" => CREDITS, "menu" => MENU,
                "episodes" => EPISODES, "difficulty" => DIFFICULTY, "playing" => PLAYING }.freeze

    # Which screen a name means, or nothing said, which means the beginning.
    def self.screen_named(name)
      return NOTICE if name.to_s.empty?

      BY_NAME.fetch(name.to_s.strip.downcase) do
        raise ArgumentError,
              "There is no screen called #{name.inspect}. " \
              "The screens are: #{BY_NAME.keys.join(', ')}."
      end
    end

    # +view+ is the game itself, which this puts a menu in front of. +art+ is Wolfenstein's own
    # menu pictures. +sound_on+ is the variable the SOUND row moves, which the game's own
    # sounds are played under.
    #
    # +starting_on+ is which screen the cartridge boots on, and it is a MEASURING TOOL rather
    # than a way to play — the same kind of dial as which floors to ship. Every screen can be
    # reached by playing, but two of them are a quarter of a minute of waiting away and one only
    # exists on a cartridge carrying more than one episode, so a cartridge that boots straight
    # to the one you want to look at is worth being able to build.
    def initialize(build:, view:, art:, palette:, sound_on:, starting_on: NOTICE)
      @b = build
      @view = view
      @art = art
      @palette = palette
      @sound_on = sound_on
      @episodes = view.floors.episodes
      @starting_on = starting_on
      declare
    end

    # ONE PASS OF THE GAME LOOP: exactly one screen runs, whichever one you are on.
    def update
      pairs = screens
      @b.case_var(:screen) { pairs.each { |state, scene| when_val state, scene } }
    end

    # EVERY SCREEN THIS CARTRIDGE HAS, and the episode list is only one of them when there is
    # more than one episode on the cartridge to choose between.
    def screens
      list = { NOTICE => :the_notice, TITLE => :the_title, CREDITS => :the_credits,
               MENU => :the_menu, DIFFICULTY => :the_difficulty, PLAYING => :playing }
      list[EPISODES] = :the_episodes if offers_episodes?
      list
    end

    # Which screen is showing, so a test can say where it got to.
    attr_reader :screen, :difficulty

    private

    def declare
      check_it_can_start_there!
      declare_the_lettering
      declare_the_art
      @screen = @b.var :screen, @starting_on
      # How long the screen you are on has been up, and where a fade is taking you. A fade is
      # running exactly while the second one holds a screen number rather than nothing.
      @waited = @b.var :_screen_waited, 0
      @going_to = @b.var :_screen_going_to, NOWHERE
      @blink = @b.var :_menu_blink, 0
      # How far the window has drifted across a picture wider than the screen, in pairs of
      # pixels — which is the only step this screen can be drawn at.
      @pan = @b.var :_screen_pan, 0
      # Whether there is a game behind the menu, which is what makes the main menu a pause
      # menu: it decides what two of its rows say and what they do.
      @in_game = @b.var :_in_game, 0
      # WHICH FLOOR A GAME WILL START ON, set by the episode list. Nothing else writes it, so a
      # cartridge with no episode list to show simply starts on the first floor it holds.
      @start_floor = @b.var :_start_floor, 0
      # HOW TOUGH YOU SAID YOU WERE. Nothing reads it yet — which guards a floor holds is
      # settled while the cartridge is built — so this is the seam and not the feature.
      @difficulty = @b.var :difficulty, NORMAL
      declare_the_fades
      declare_the_screens
    end

    # No screen at all, which is what "no fade is running" is written as.
    NOWHERE = -1

    # A cartridge asked to boot on a screen it does not carry would boot to nothing at all, so
    # it says so instead. The one screen that can be missing is the episode list.
    def check_it_can_start_there!
      return if screens.key?(@starting_on)

      raise ArgumentError,
            "This cartridge has no episode list to start on. It holds #{@episodes.length} " \
            "episode. To fix this, build it with more floors. Or start on another screen."
    end

    def declare_the_lettering
      @b.font LETTERING, glyphs: @art.font(0)
      @b.font HEADING, glyphs: @art.font(1)
    end

    def declare_the_art
      %i[notice title credits menu_heading menu_gun menu_gun_firing].each { |name| picture(name) }
      DIFFICULTIES.each { |(_, portrait)| picture(portrait) }
    end

    def picture(name)
      cut = @art.picture(name, @palette)
      @b.image :"menu_#{name}", width: cut[:width], height: cut[:height], data: cut[:data]
      name
    end

    # THE FADE, AS TWO ROUTINES rather than as code in each screen. Three screens can start a
    # fade and each would otherwise carry its own copy of it; more to the point, a fade is one
    # thing the display does, so there should be one place that says how this game fades.
    def declare_the_fades
      @b.func(:_menu_fade_out) { @b.fade_out fade_colour, frames: FADE_FRAMES }
      @b.func(:_menu_fade_in) { @b.fade_in }
    end

    def declare_the_screens
      still_screen(:the_notice, :notice, after: TITLE, holding: NOTICE_FRAMES)
      still_screen(:the_title, :title, after: CREDITS, holding: TITLE_FRAMES)
      still_screen(:the_credits, :credits, after: TITLE, holding: CREDITS_FRAMES)
      declare_the_menu
      declare_the_episodes if offers_episodes?
      declare_the_difficulty
      declare_the_game
    end

    # --- THE ATTRACT LOOP ------------------------------------------------------------------

    # A SCREEN THAT SHOWS ONE PICTURE AND WAITS: for its own time to run out, which moves it on
    # to the next of them, or for anybody to touch the pad, which opens the menu. The whole
    # attract loop is three of these.
    def still_screen(name, art, after:, holding:)
      wide, tall = @art.size(art)
      travel = (wide - ACROSS) / 2
      @b.scene(name) do
        show(art, wide: wide, tall: tall, travel: travel, over: holding)
        @waited.add 1
        (@waited >= holding).then { go_to after }
        # A PRESS ALWAYS WINS, and it wins whichever way round these two are asked: moving on
        # puts the clock back to nothing, so the screen that arrives is the one the press
        # asked for either way. A player who touched the pad meant the menu.
        anybody_pressing.then { go_to MENU }
      end
    end

    # THE PICTURE: centred where it fits, and where it does not, the SCREEN drifts across it.
    #
    # The title and the credits were painted a third wider than this screen, and squeezing them
    # to fit is what turns their lettering to mush (see MenuArt). So nothing is squeezed across:
    # every column is kept and the window walks over the eighty that do not fit, out and back,
    # over about four fifths of the time the screen is up. It costs one drawing a frame, which
    # is what a still picture cost anyway.
    #
    # IT MOVES TWO PIXELS AT A TIME because this screen holds two pixels in each of its places
    # and will not take one, so an odd column is not a column a picture can start at. Twice
    # anything is even, which is how the drift is written and how the framework's own refusal
    # says to write it.
    def show(art, wide:, tall:, travel:, over:)
      down = (DOWN - tall) / 2
      @b.clear_screen colour(0) unless [wide, tall] == [ACROSS, DOWN]
      return @b.blit(:"menu_#{art}", even((ACROSS - wide) / 2), down) unless travel.positive?

      @pan.set(@waited / pan_step(travel, over))
      # Out and back: past the far end it walks home again.
      (@pan > travel).then { @pan.set((travel * 2) - @pan) }
      @pan.clamp 0, travel
      @b.blit :"menu_#{art}", -(@pan * 2), down
    end

    # How many frames each two-pixel step holds for, so the drift out and back takes about four
    # fifths of the time the screen is up and settles for the rest of it. Never less than one.
    def pan_step(travel, over) = [(over * 4 / 5) / (travel * 2), 1].max

    # ANY BUTTON AT ALL, which is how you get out of the attract loop. Written out one button
    # at a time because that is the only way to say it: the framework has a test for each
    # button and none for "somebody is touching this".
    BUTTONS = %i[a b start select left right up down l r].freeze

    def anybody_pressing = BUTTONS.map { |button| @b.held(button) }.reduce(:|)

    # --- THE MAIN MENU, WHICH IS ALSO THE PAUSE MENU -----------------------------------------

    def declare_the_menu
      rows = NEW_GAME + [LOAD_GAME] + SOUND + BACK
      at = layout_for(rows)
      y = rows_top(@art.height(:menu_heading) + HEADING_GAP, 4)
      @b.scene(:the_menu) do
        the_ground
        the_stripes
        @b.blit :menu_menu_heading, even((ACROSS - @art.width(:menu_heading)) / 2), 0
        the_window(at, y, 4)
        picked = the_rows(:main, at, y) do |m|
          m.item(NEW_GAME, showing: @in_game) { new_game_or_end_it }
          m.item(LOAD_GAME, enabled: false)
          m.item(SOUND, showing: @sound_on) { @sound_on.set 1 - @sound_on }
          m.item(BACK, showing: @in_game) { leave_the_menu }
        end
        the_gun(at, y, picked)
        arriving
      end
    end

    # ONE ROW, TWO MEANINGS, which is the row the pause menu turns over. Outside a game it
    # starts one; inside a game it ends the one you are in and leaves you at the title.
    def new_game_or_end_it
      (@in_game == 1).then { @in_game.set 0; leaving_for TITLE }
                     .else { leaving_for(offers_episodes? ? EPISODES : DIFFICULTY) }
    end

    # ...and so is the last row: back to the loop of still screens, or back to the game.
    def leave_the_menu
      (@in_game == 1).then { leaving_for PLAYING }.else { leaving_for TITLE }
    end

    # --- THE EPISODE LIST --------------------------------------------------------------------

    # Only worth a screen when the cartridge holds more than one episode to start. A build with
    # one has nothing to ask, and a build begun in the MIDDLE of an episode — which is what
    # WOLF3D_FROM makes, for measuring a later floor — has no episode start at all.
    def offers_episodes? = @episodes.length > 1

    def declare_the_episodes
      at = layout_for(EPISODE_NAMES)
      y = rows_top(under_a_written_heading, EPISODE_NAMES.length)
      @b.scene(:the_episodes) do
        the_ground
        @b.draw_text WHICH_EPISODE, :center, HEADING_Y, colour(TEXT), font: HEADING
        picked = the_rows(:episodes, at, y) do |m|
          EPISODE_NAMES.each_with_index do |name, n|
            slot = @episodes[n + 1]
            # An episode this cartridge does not hold is there to be seen and not to be
            # picked, so it has nothing to do either.
            next m.item(name, enabled: false) if slot.nil?

            m.item(name) { @start_floor.set slot; leaving_for DIFFICULTY }
          end
        end
        the_gun(at, y, picked)
        arriving
      end
    end

    # --- THE DIFFICULTY SCREEN ---------------------------------------------------------------

    def declare_the_difficulty
      at = layout_for(DIFFICULTIES.map(&:first))
      y = rows_top(under_a_written_heading, DIFFICULTIES.length)
      @b.scene(:the_difficulty) do
        the_ground
        @b.draw_text HOW_TOUGH, :center, HEADING_Y, colour(TEXT), font: HEADING
        picked = the_rows(:difficulty, at, y) do |m|
          DIFFICULTIES.each_with_index do |(words, _), n|
            m.item(words) { @difficulty.set n; start_the_game }
          end
        end
        the_portrait(y, picked)
        the_gun(at, y, picked)
        arriving
      end
    end

    # THE PORTRAIT BESIDE THE ROWS, which is the whole reason this screen is not a plain list:
    # BJ gets grimmer as you move down it, so the picture answers the question the rows ask.
    #
    # FOUR DRAWINGS UNDER FOUR TESTS rather than one picture of all four side by side, which is
    # how the bar's twenty-four faces are done. The trick pays when the set is big, or when the
    # picture is being walked a column at a time anyway; here it would turn one copied block
    # into twenty-four column walks to save three tests on a screen with nothing else to do.
    def the_portrait(rows_y, picked)
      wide, tall = @art.size(DIFFICULTIES.first.last)
      x = even(ACROSS - wide - PORTRAIT_MARGIN)
      y = rows_y + (((DIFFICULTIES.length * ROW_STEP) - tall) / 2)
      DIFFICULTIES.each_with_index do |(_, portrait), n|
        (picked == n).then { @b.blit :"menu_#{portrait}", x, y }
      end
    end

    PORTRAIT_MARGIN = 12

    # --- THE GAME ----------------------------------------------------------------------------

    def declare_the_game
      @b.scene(:playing) do
        @view.update
        pausing
      end
    end

    # START OPENS THE MENU, and it opens it at once rather than fading — the fade belongs to
    # LEAVING a menu, which is what the original fades.
    #
    # UNLESS THE GAME IS OVER, and then START means the other thing it has always meant here:
    # begin another game where you fell. The two never overlap, so one button does both.
    def pausing
      pause = -> { @b.pressed(:start).then { @in_game.set 1; go_to MENU } }
      over = @view.over
      over ? (over == 0).then { pause.call } : pause.call
    end

    # A GAME BEGINS: on the floor the episode list picked, with a fresh player, and then the
    # screen fades away to leave you in it.
    def start_the_game
      @view.begin_a_new_game(@start_floor)
      @in_game.set 1
      leaving_for PLAYING
    end

    # --- THE CHROME EVERY MENU SHARES --------------------------------------------------------

    def the_ground = @b.clear_screen(colour(BACKGROUND))

    # A BLACK BAND WITH A COLOURED RULE ALONG THE BOTTOM OF IT, which is what the heading plate
    # sits on. The band is wider than the plate, so it runs out either side of it.
    def the_stripes
      @b.dma_fill_rect 0, STRIPE_Y, ACROSS, STRIPE_H, colour(0)
      @b.dma_fill_rect 0, STRIPE_Y + STRIPE_RULE, ACROSS, 1, colour(STRIPE)
    end

    # THE BEVELLED WINDOW BEHIND THE ROWS: an outline in two colours, the lighter along the top
    # and down the left, the darker along the bottom and up the right. Two colours rather than
    # one is the whole of what makes it read as cut into the screen rather than drawn on it.
    #
    # Drawn with the rectangle that takes any width, because a line down the side of it is ONE
    # pixel wide and the block fills on this screen want an even number.
    #
    # THE GUN IS INSIDE IT, so the window is measured from the gun's own column rather than
    # from the lettering's — a selector hanging outside the frame it points into reads as a
    # mistake.
    def the_window(at, y, rows)
      left = at.gun_x - WINDOW_PAD_X
      top = y - WINDOW_PAD_Y
      w = (at.rows_x - left) + at.wide + WINDOW_PAD_X
      h = (rows * ROW_STEP) + (WINDOW_PAD_Y * 2)
      @b.draw_rect_at left, top, w, 1, colour(BORDER)
      @b.draw_rect_at left, top, 1, h, colour(BORDER)
      @b.draw_rect_at left, top + h - 1, w, 1, colour(BORDER_SHADOW)
      @b.draw_rect_at left + w - 1, top, 1, h, colour(BORDER_SHADOW)
    end

    # THE ROWS THEMSELVES. Every menu in this game is drawn the same way, so the three colours
    # and the spacing and the button are said once here; what differs is only the rows.
    #
    # NO CURSOR OF THE FRAMEWORK'S OWN — the gun is drawn separately, because it is a picture
    # rather than a character and because it blinks.
    def the_rows(name, at, y, &rows)
      @b.menu(name, at: [at.rows_x, y], spacing: ROW_STEP, font: LETTERING, cursor: "",
                    color: colour(TEXT), picked: colour(HIGHLIGHT), disabled: colour(DISABLED),
                    press: :a, repeat_every: HELD_REPEAT, &rows).picked
    end

    # THE GUN, pointing at the row you are on and blinking: itself for a second, then itself
    # with its muzzle flashing for about a ninth of one.
    def the_gun(at, y, picked)
      tall = @art.height(:menu_gun)
      row = (picked * ROW_STEP) + y + ((ROW_STEP - tall) / 2)
      @blink.add 1
      (@blink >= BLINK_ON + BLINK_OFF).then { @blink.set 0 }
      (@blink < BLINK_ON).then { @b.blit :menu_menu_gun, at.gun_x, row }
                         .else { @b.blit :menu_menu_gun_firing, at.gun_x, row }
    end

    # --- MOVING BETWEEN SCREENS --------------------------------------------------------------

    # STRAIGHT TO ANOTHER SCREEN, with the clock on the new one started from nothing.
    def go_to(screen)
      @screen.set screen
      @waited.set 0
    end

    # ...and the other way, which is what picking a row does: the screen fades away first and
    # the new one is not shown until it has gone. A second choice while a fade is running is
    # ignored, which is what the guard is for — the original simply stops reading the pad.
    def leaving_for(screen)
      (@going_to == NOWHERE).then do
        @going_to.set screen
        @b.call :_menu_fade_out
      end
    end

    # THE OTHER HALF OF THAT, run by every menu on every frame: once the screen has gone
    # completely dark, swap to what was waiting behind it and bring it back up.
    #
    # THE TEST IS ON THE ERRAND AND NOT ONLY ON THE DARKNESS. A fade that has just been asked
    # to come back is still at its darkest on the frame after it started, so a screen watching
    # the darkness alone would arrive twice.
    def arriving
      (@going_to != NOWHERE).then do
        (@b.fade_level == 100).then do
          go_to @going_to
          @going_to.set NOWHERE
          @b.call :_menu_fade_in
        end
      end
    end

    # --- LAYING A SCREEN OUT ------------------------------------------------------------------

    # WHERE ONE SCREEN'S ROWS GO ACROSS: the column the lettering starts at, the column the gun
    # hangs in beside it, and how wide the widest row comes out.
    Layout = Data.define(:rows_x, :gun_x, :wide)

    # Worked out from the alphabet rather than counted in pixels, so a row can be reworded and
    # nothing here is left stale. The pair — the gun and the rows — is centred as one thing, so
    # a screen of short rows is not pushed to one side by the gun beside them.
    def layout_for(labels)
      room = @art.width(:menu_gun) + GUN_GAP
      wide = widest(labels)
      x = [((ACROSS - room - wide) / 2) + room, room].max
      Layout.new(rows_x: x, gun_x: even(x - room), wide: wide)
    end

    def widest(labels) = labels.map { |words| @b.text_width(words, font: LETTERING) }.max

    # WHERE A SCREEN'S ROWS BEGIN DOWN THE SCREEN: centred in whatever is left under its
    # heading, so no screen carries a row position typed in by hand and a list of six sits as
    # well as a list of four.
    def rows_top(under, count) = under + ((DOWN - under - (count * ROW_STEP)) / 2)

    def under_a_written_heading = HEADING_Y + @b.text_height(font: HEADING) + HEADING_GAP

    def colour(ink) = @palette[ink]

    def fade_colour = @b.rgb(*FADE_CHANNELS.map { |channel| channel * 31 / 63 })

    # A PICTURE MUST START ON AN EVEN COLUMN on this screen, which takes two pixels at a time
    # and will not take one.
    def even(x) = x - (x % 2)
  end
end
