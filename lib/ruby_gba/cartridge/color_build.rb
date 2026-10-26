# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # THE GAME BOY COLOR'S CARTRIDGE, made from a checked program by IR::Backends::GBC (see
    # Console::ColorKit). Measuring, quick memory and the ROM validation are the Advance's and are
    # not asked for. A routine asked to be listed (`dump_func`) is listed as the ARM it was made
    # into, which only the Advance has, so it is refused in the words of the Color's answers.
    module ColorBuild
      module_function

      # The cartridge for +request+ (a Cartridge::BuildRequest). The findings are left as they were.
      def build(request)
        dumps = request.evaluated.dump_requests
        unless dumps.empty?
          raise ROMError, "This game lists a routine's ARM (`dump_func #{dumps.first.inspect}`), and a " \
                          "#{Console::COLOR.title} cannot: #{Console::GBCFeatures.answer(:dump_func).words} Take out " \
                          "`dump_func`, or build for the Game Boy Advance alone to see it."
        end

        request.progress.step("lowering for the #{Console::COLOR.title}")
        IR::Backends::GBC.new.build(request.program, title: request.title)
      end
    end
  end
end
