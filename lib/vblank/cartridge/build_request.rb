# frozen_string_literal: true

module VBlank
  module Cartridge
    # WHAT A CONSOLE'S BUILD IS HANDED, once the game has been read and checked: everything
    # VBlank.build knows by then, in one value, for the build its console's kit names
    # (Console::Kit#builder) to make the cartridge from.
    #
    # +program+ is the checked tree and +evaluated+ the game it came from (its dump requests and
    # whether it stopped at a debug_halt). +findings+ are the guardrails' findings, nil for a
    # debug_halt build; a build that checks what it decided adds its own to them here, so that
    # whatever happens after, they are printed with the rest. +title+, +code+, +maker+ and
    # +validate+ are what VBlank.build was given for the cartridge, +options+ how the game is
    # built (Cartridge::Options), +profile+ a measured routine profile or false, and +progress+,
    # +out+ and +err+ where the build says what it is doing.
    #
    # NOT FROZEN, for that one field: the findings are the build's to add to as it goes.
    BuildRequest = Struct.new(:program, :evaluated, :findings, :title, :code, :maker, :validate, :options,
                              :profile, :progress, :out, :err, keyword_init: true)
  end
end
