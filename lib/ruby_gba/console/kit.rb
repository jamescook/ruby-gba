# frozen_string_literal: true

module RubyGBA
  module Console
    # WHICH PARTS OF THE LIBRARY SERVE EACH CONSOLE, asked of one place.
    #
    # A game is built, checked, read back and tested the same way whichever console it is for,
    # and at a handful of points the console decides how: which build makes its cartridge, which
    # kind of cartridge that is, which reader plays it back, what a verb does on it. Each of those
    # points used to ask "is it the Color?" for itself, so a console added meant finding every one
    # of them, and every one's "no" meant the Advance. Here each console has one kit naming them
    # all, and a part of the library that needs to know asks Console.for(name) and uses what it is
    # handed. A console is added by describing it and giving it a kit, here and nowhere else.
    #
    # A kit names parts and does none of their work: each is its own module's, named here and
    # asked for when a build or a reader needs it, which is long after every module is loaded.
    #
    # What every kit answers:
    #
    #   description             what a game can tell about the console (Console::Description)
    #   answers                 what each verb does on it (Console::GBCFeatures, say), or nil for
    #                           a console where every verb works as the Advance's does
    #   builder                 what makes its cartridge from a checked program, given a
    #                           Cartridge::BuildRequest (Cartridge::AdvanceBuild, say)
    #   cartridge               the kind of cartridge that is
    #   reader                  the reader that plays one back (Diagnostics::Verifier, say)
    #   measured_builds?        whether its build is measured by running it, which is what chooses
    #                           what goes in a quick memory, and what its cartridge reports of
    #                           packing and placement
    #   compared_side_by_side?  whether two of its cartridges can be compared side by side
    #                           (Playthroughs::Comparison lines screens up at the Advance's size)
    class Kit
      attr_reader :description

      def initialize(description)
        @description = description
        freeze
      end

      def name = description.name
      def title = description.title
      def answers = nil
      def measured_builds? = false
      def compared_side_by_side? = false
    end

    # The Game Boy Advance's.
    class AdvanceKit < Kit
      def builder = Cartridge::AdvanceBuild
      def cartridge = Cartridge::ROM
      def reader = Diagnostics::Verifier
      def measured_builds? = true
      def compared_side_by_side? = true
    end

    # The Game Boy Color's.
    class ColorKit < Kit
      def answers = GBCFeatures
      def builder = Cartridge::ColorBuild
      def cartridge = Cartridge::GBCROM
      def reader = Diagnostics::GBCVerifier
    end

    KITS = Ractor.make_shareable({ gba: AdvanceKit.new(ADVANCE), gbc: ColorKit.new(COLOR) })

    # What a game can tell about each console, by name.
    DESCRIPTIONS = Ractor.make_shareable(KITS.transform_values(&:description))

    # The kit for the console named +name+ (a Symbol or a String). A name no console has is
    # refused with the names there are.
    def self.for(name)
      KITS.fetch(name.to_sym) do
        raise ArgumentError, "there is no console named #{name.inspect}. The consoles are " \
                             "#{KITS.keys.map(&:inspect).join(' and ')}."
      end
    end

    # Every console's kit.
    def self.kits = KITS.values

    # The console named +name+, the Advance for nil.
    def self.described(name) = name.nil? ? ADVANCE : self.for(name).description
  end
end
