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
    # +backgrounds+ is how many tiled layers it stacks, and +turning_backgrounds+ how many of
    # them can turn and resize. +blends+ says whether its display can mix colours as it draws —
    # fade the finished picture, mix one layer into another — rather than only change the colours
    # in its lists. +list_colors+ is how many places a list of colours holds. +painted_pages+ is
    # how many pictures a tear-free painted screen keeps: two where one is drawn while the other
    # is shown, one where the console only ever shows a picture whole. +clock_keeps_date+ says
    # whether the clock chip its cartridges carry holds the date and time, or only counts the days
    # and the time of day since it started (IR::Clock). +extension+ ends the name of a cartridge
    # file for it.
    Description = Data.define(:name, :title, :screen_width, :screen_height, :buttons, :sprites, :sprite_places,
                              :backgrounds, :turning_backgrounds, :blends, :list_colors, :painted_pages,
                              :clock_keeps_date, :extension) do
      def screen_size = [screen_width, screen_height]

      # The middle of the screen, in whole pixels.
      def middle = [screen_width / 2, screen_height / 2]
    end

    # The Game Boy Advance.
    ADVANCE = Description.new(name: :gba, title: "Game Boy Advance", screen_width: 240, screen_height: 160,
                              buttons: %i[a b select start right left up down r l].freeze, sprites: 128,
                              # The most the desktop and web builds draw in one frame, too.
                              sprite_places: 512,
                              backgrounds: 4, turning_backgrounds: 1, blends: true, list_colors: 16,
                              painted_pages: 2, clock_keeps_date: true, extension: ".gba")

    # The Game Boy Color: a smaller screen, eight buttons, forty sprites, one background, lists of
    # four colours, and a clock that counts days. What each verb does on it is
    # Console::GBCFeatures's to say.
    COLOR = Description.new(name: :gbc, title: "Game Boy Color", screen_width: 160, screen_height: 144,
                            buttons: %i[a b select start right left up down].freeze, sprites: 40, sprite_places: 40,
                            backgrounds: 1, turning_backgrounds: 0, blends: false, list_colors: 4,
                            painted_pages: 1, clock_keeps_date: false, extension: ".gbc")

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
