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
    #   answers                 what each verb does on it (Console::Answers): works, or refused
    #   answers_page            those answers written out for the reader, with anything the page
    #                           says of the console's build (what the Color's does not make yet)
    #   builder                 what makes its cartridge (Cartridge::AdvanceBuild, say). It answers
    #                           build(request), the cartridge from a checked program and a
    #                           Cartridge::BuildRequest; console_settings, the names of the CONSOLE
    #                           SETTINGS it reads (build settings only some consoles have, such
    #                           as the Advance's `stack_room:`); and refuse_unusable_settings!(said),
    #                           which refuses a value of one of those it cannot use
    #   cartridge               the kind of cartridge that is (below)
    #   reader                  the reader that plays one back (Diagnostics::Verifier, say)
    #   measured_builds?        whether its build is measured by running it, which is what chooses
    #                           what goes in a quick memory, and what its cartridge reports of
    #                           packing and placement
    #   compared_side_by_side?  whether two of its cartridges can be compared side by side
    #                           (Playthroughs::Comparison lines screens up at the Advance's size)
    #   drawn_by_runtimes?      whether the desktop program and the web page can be made from its
    #                           build: the C and JavaScript runtimes draw one screen size, fixed
    #                           when they are compiled, and it is the Advance's
    #
    # What every console's cartridge answers, whichever kind it is, and all a caller that has not
    # asked which console it is for can ask of one:
    #
    #   console                    the name of the console it is for (also asked of its class)
    #   buffer, size               its bytes, and how many there are
    #   header_title               the title field of its header, as the header holds it
    #   write(path)                its bytes, written to +path+
    #   built                      what the build worked out about it, or nil
    #   source_program             the checked program it was built from
    #   var_addresses              where the build put each of the game's variables
    #   profile(format:, out:, frames:, settle:, keys:, scene:, from:)
    #                              where its frames went, run in the emulator
    #
    # and its class answers header?(bytes), whether +bytes+ are a cartridge of its kind, and
    # title_field_of(bytes). Anything else one kind has (the Advance's ROM#placement, say) is
    # asked only by code that already knows which console it holds.
    class Kit
      attr_reader :description

      def initialize(description)
        @description = description
        freeze
      end

      def name = description.name
      def title = description.title
      def measured_builds? = false
      def compared_side_by_side? = false
      def drawn_by_runtimes? = false

      # The console settings its build reads, by name, and whether +setting+ is one of them.
      def console_settings = builder.console_settings
      def console_setting?(setting) = console_settings.include?(setting)
    end

    # The Game Boy Advance's.
    class AdvanceKit < Kit
      def answers = AdvanceAnswers
      def answers_page = answers.reference
      def builder = Cartridge::AdvanceBuild
      def cartridge = Cartridge::ROM
      def reader = Diagnostics::Verifier
      def measured_builds? = true
      def compared_side_by_side? = true
      def drawn_by_runtimes? = true
    end

    # The Game Boy Color's.
    class ColorKit < Kit
      def answers = ColorAnswers
      def answers_page = answers.reference(not_yet: IR::Backends::GBC::Lowering::NOT_LOWERED_YET)
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
      KITS.fetch(name&.to_sym) do
        named = name.nil? ? "No console is named" : "There is no console named #{name.inspect}"
        raise ArgumentError, "#{named}. The consoles are #{KITS.keys.map(&:inspect).join(' and ')}."
      end
    end

    # Every console's kit.
    def self.kits = KITS.values

    # Of the consoles +names+, the first whose build the desktop and web runtimes draw
    # (Kit#drawn_by_runtimes?), or nil when there is none.
    def self.drawn_by_runtimes(names) = names.find { |name| self.for(name).drawn_by_runtimes? }

    # Every console setting there is, by name: a build setting only some consoles have
    # (Kit#console_settings).
    def self.console_settings = kits.flat_map(&:console_settings).uniq

    # Of +values+ (a setting's name to its value, as a game or a build was given them), the
    # console settings that were said: the ones that are not nil.
    def self.console_settings_said(values) = values.slice(*console_settings).compact

    # A SETTING SAID FOR A CONSOLE THAT DOES NOT HAVE IT is refused, rather than dropped: the author
    # asked for something the cartridge would not have.
    #
    # +said+ is the console settings that were said, by name, to their values
    # (console_settings_said); +consoles+ the consoles the game or the build is for; +title+ the
    # game's; and +named_in+ the keyword those consoles were named with (`consoles:` for a game,
    # `console:` for a build), so the fix says where to add one. A setting is refused when none of
    # +consoles+ has it, and a value when a console that has it cannot use it.
    def self.refuse_unusable_console_settings!(said, consoles:, title:, named_in:)
      kits = consoles.map { |name| self.for(name) }
      said.each_key do |setting|
        next if kits.any? { |kit| kit.console_setting?(setting) }

        holders = self.kits.select { |kit| kit.console_setting?(setting) }.map(&:title)
        raise ArgumentError, "`#{setting}:` is set for #{title}. Only the #{holders.join(' and the ')} " \
                             "#{holders.size == 1 ? 'has' : 'have'} this setting. #{title} is for the " \
                             "#{kits.map(&:title).join(' and the ')}. To fix this, remove `#{setting}:`. Or name " \
                             "the #{holders.first} in `#{named_in}`."
      end
      kits.each { |kit| kit.builder.refuse_unusable_settings!(said.slice(*kit.console_settings)) }
    end

    # What a game can tell about the console named +name+.
    def self.described(name) = self.for(name).description

    # The console +name+ names, as the Symbol every part of the library holds it as, so a console
    # named in a String is the same console and never a name compared and missed. A name no
    # console has is refused.
    def self.named(name) = self.for(name).name
  end
end
