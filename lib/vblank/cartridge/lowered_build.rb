# frozen_string_literal: true

module VBlank
  module Cartridge
    # THE CARTRIDGE OF A CONSOLE WHOSE LOWERING IS CHECKED BY A RUN OF ITS OWN — the Game Boy
    # Color's and the Super Nintendo's — made from a checked program by the lowering its kit names
    # (Console::CheckedKit#lowering). One build serves every such console, and the kit is what it is
    # handed: what differs from one console to the next is the lowering, and the kit names it.
    #
    # Measuring, quick memory and the ROM validation are the Advance's and are not asked for, and a
    # build that says one of the Advance's settings is refused before it gets here
    # (Cartridge::AdvanceBuild::SETTINGS). A routine asked to be listed (`dump_func`) is listed as
    # the ARM it was made into, which only the Advance has, so it is refused in the words of the
    # console's own answers.
    LoweredBuild = Data.define(:kit) do
      # These consoles have no setting of their own: what they are built with every console has.
      def console_settings = []
      def refuse_unusable_settings!(_said) = nil

      # The cartridge for +request+ (a Cartridge::BuildRequest). The findings are left as they were.
      def build(request)
        dumps = request.evaluated.dump_requests
        unless dumps.empty?
          raise ROMError, "This game lists a routine's ARM (`dump_func #{dumps.first.inspect}`), and a " \
                          "#{kit.title} cannot: #{kit.answers.answer(:dump_func).words} Take out " \
                          "`dump_func`, or build for the Game Boy Advance alone to see it."
        end

        request.progress.step("lowering for the #{kit.title}")
        cartridge_for(request.program, title: request.title)
      end

      # The cartridge for +program+ alone, titled +title+. What a test that plays a cartridge
      # builds (Testing::Pictures).
      def cartridge_for(program, title:) = kit.lowering.new.build(program, title: title)
    end
  end
end
