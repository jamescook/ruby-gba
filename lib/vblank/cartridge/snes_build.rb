# frozen_string_literal: true

module VBlank
  module Cartridge
    # THE SUPER NINTENDO'S CARTRIDGE, made from a checked program by IR::Backends::SNES (see
    # Console::SNESKit). Measuring, quick memory and the ROM validation are the Advance's and are not
    # asked for. A routine asked to be listed (`dump_func`) is listed as the ARM it was made into,
    # which only the Advance has, so it is refused in the words of the Super Nintendo's answers.
    module SNESBuild
      module_function

      # The Super Nintendo has no setting of its own: what it is built with every console has.
      def console_settings = []
      def refuse_unusable_settings!(_said) = nil

      # The cartridge for +request+ (a Cartridge::BuildRequest).
      def build(request)
        dumps = request.evaluated.dump_requests
        unless dumps.empty?
          raise ROMError, "This game lists a routine's ARM (`dump_func #{dumps.first.inspect}`), and a " \
                          "#{Console::SUPER_NINTENDO.title} cannot: #{Console::SNESAnswers.answer(:dump_func).words} " \
                          "Take out `dump_func`, or build for the Game Boy Advance alone to see it."
        end

        request.progress.step("lowering for the #{Console::SUPER_NINTENDO.title}")
        cartridge_for(request.program, title: request.title)
      end

      # The cartridge for +program+ alone, titled +title+. What a test that plays a cartridge builds.
      def cartridge_for(program, title:) = IR::Backends::SNES.new.build(program, title: title)
    end
  end
end
