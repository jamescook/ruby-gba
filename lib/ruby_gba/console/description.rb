# frozen_string_literal: true

module RubyGBA
  module Console
    # WHAT A CONSOLE IS, AS FAR AS A GAME CAN TELL: how big its screen is, which buttons it has, how
    # many sprites it shows, and which of the picture's tricks it can do at all. The builder, the
    # build checks and the interpreter read these, so a game is laid out, checked and played for the
    # screen it will be shown on.
    #
    # It says nothing about HOW the console is driven — register addresses, memory, the processor —
    # which is each lowering's own business (Console::Hardware is the Advance's). A program carries
    # the name of the console it was built for, and anything that reads it asks
    # Program#described_console.
    #
    # +name+ is how a game and the command line name it (:gba), +title+ how a person does.
    # +screen_width+ and +screen_height+ are in pixels. +buttons+ are the ones it has, in the
    # order IR::Buttons names them. +sprites+ is how many it can show at once, and +sprite_places+
    # how many a game can keep places for: more than it shows where a cartridge keeps a bigger
    # copy of its table and puts the sprites showing into the console's each frame, as the
    # Advance's does (Backends::GBA::SpriteDrawing::HeldTable), and the same where it does not.
    # +sprites_a_row+ is how many pieces of sprites, eight pixels wide, it draws on one row of the
    # screen before it leaves the rest of that row's out, or nil where the build does not count
    # them. +backgrounds+ is how many tiled layers it stacks, +turning_backgrounds+ how many of
    # them can turn and resize, and +backgrounds_beside_turning+ how many still scroll on a screen
    # where one turns. +turning_sprites+ says whether a sprite can turn and resize.
    # +blends+ says whether its display can mix colours as it draws —
    # fade the finished picture, mix one layer into another — rather than only change the colours
    # in its lists. +list_colors+ is how many places a list of colours holds. +painted_pages+ is
    # how many pictures a tear-free painted screen keeps: two where one is drawn while the other
    # is shown, one where the console only ever shows a picture whole. +clock_keeps_date+ says
    # whether the clock chip its cartridges carry holds the date and time, or only counts the days
    # and the time of day since it started (IR::Clock). +extension+ ends the name of a cartridge
    # file for it.
    Description = Data.define(:name, :title, :screen_width, :screen_height, :buttons, :sprites, :sprite_places,
                              :sprites_a_row, :turning_sprites, :backgrounds, :turning_backgrounds,
                              :backgrounds_beside_turning, :blends, :list_colors, :painted_pages,
                              :clock_keeps_date, :extension) do
      def screen_size = [screen_width, screen_height]

      # Whether any of its backgrounds can turn and resize.
      def turns_backgrounds? = turning_backgrounds.positive?

      # How many backgrounds scroll at one time, on a screen where one turns or where none does.
      def scrolling_backgrounds(turning:) = turning ? backgrounds_beside_turning : backgrounds

      # The middle of the screen, in whole pixels.
      def middle = [screen_width / 2, screen_height / 2]
    end

    # The Game Boy Advance.
    ADVANCE = Description.new(name: :gba, title: "Game Boy Advance", screen_width: 240, screen_height: 160,
                              buttons: %i[a b select start right left up down r l].freeze, sprites: 128,
                              # The most the desktop and web builds draw in one frame, too.
                              sprite_places: 512,
                              # What limits a row on the Advance is the time the display has to
                              # draw it, which depends on how wide each sprite is and whether it
                              # turns, and the build does not work that out.
                              sprites_a_row: nil, turning_sprites: true,
                              # Four layers that scroll, or two that scroll and one that turns.
                              backgrounds: 4, turning_backgrounds: 1, backgrounds_beside_turning: 2,
                              blends: true, list_colors: 16, painted_pages: 2, clock_keeps_date: true,
                              extension: ".gba")

    # The Game Boy Color: a smaller screen, eight buttons, forty sprites and ten on a row, one
    # background, nothing that turns, lists of four colours, and a clock that counts days. What
    # each verb does on it is Console::ColorAnswers's to say.
    COLOR = Description.new(name: :gbc, title: "Game Boy Color", screen_width: 160, screen_height: 144,
                            buttons: %i[a b select start right left up down].freeze, sprites: 40, sprite_places: 40,
                            sprites_a_row: 10, turning_sprites: false,
                            backgrounds: 1, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                            blends: false, list_colors: 4, painted_pages: 1, clock_keeps_date: false,
                            extension: ".gbc")

    # Each console's description is reached through its kit (Console::Kit, Console.described).

    # The consoles a game says it is for, as a frozen list of names: one name or a list of them.
    # A name no console has, or no name at all, is refused, since no console is the one a game is
    # for when it does not say. +setting+ is what the game wrote them in (`consoles:` where the
    # game is named, `t.consoles` in its Rakefile), so both are checked alike and the refusal says
    # which.
    def self.refuse_unknown_consoles!(consoles, setting:)
      named = Array(consoles).map(&:to_sym)
      named.each { |name| described(name) }
      if named.empty?
        raise ArgumentError, "#{setting} names no console. Name the consoles the game is for: " \
                             "`%i[gba]` for the Game Boy Advance alone, or `%i[gba gbc]` for the Game Boy Color too."
      end

      named.freeze
    end
  end
end
