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
    # Console.described(program.console).
    #
    # +name+ is how a game and the command line name it (:gba), +title+ how a person does.
    # +screen_width+ and +screen_height+ are in pixels. +buttons+ are the ones it has, in the
    # order IR::Buttons names them. +sprites+ is how many it can show at once.
    # +backgrounds+ is how many tiled layers it stacks, and +turning_backgrounds+ how many of
    # them can turn and resize. +list_colors+ is how many places a list of colours holds.
    # +extension+ ends the name of a cartridge file for it.
    Description = Data.define(:name, :title, :screen_width, :screen_height, :buttons, :sprites,
                              :backgrounds, :turning_backgrounds, :list_colors, :extension) do
      def screen_size = [screen_width, screen_height]

      # The middle of the screen, in whole pixels.
      def middle = [screen_width / 2, screen_height / 2]
    end

    # The Game Boy Advance, which every game is built for unless it says otherwise.
    ADVANCE = Description.new(name: :gba, title: "Game Boy Advance", screen_width: 240, screen_height: 160,
                              buttons: %i[a b select start right left up down r l].freeze, sprites: 128,
                              backgrounds: 4, turning_backgrounds: 1, list_colors: 16, extension: ".gba")

    DESCRIPTIONS = Ractor.make_shareable({ gba: ADVANCE })

    # The console a game is built for when it does not say.
    DEFAULT = :gba

    # The console named +name+ (a Symbol), the Advance for nil. A name no console has is refused
    # with the names there are.
    def self.described(name)
      return ADVANCE if name.nil?

      DESCRIPTIONS.fetch(name.to_sym) do
        raise ArgumentError, "there is no console named #{name.inspect}. The consoles are " \
                             "#{DESCRIPTIONS.keys.map(&:inspect).join(' and ')}."
      end
    end
  end
end
