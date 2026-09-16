# frozen_string_literal: true

require "json"

# Regenerate lib/ruby_gba/data/known_game_codes.txt — the four-character codes of
# every real Game Boy Advance cartridge an emulator's catalogue knows about: the ones
# that were sold, and the prototypes, betas and kiosk builds that got out too. A
# prototype's code is as taken as a hit's — an emulator matches it the same way.
#
# Why the framework carries this list at all is explained on RubyGBA::Cartridge::GameCode.
#
# The list is final. The last Game Boy Advance cartridge shipped in 2008, so nothing
# will be added to it — which is what makes shipping it honest rather than a
# database the framework would have to keep chasing.
#
# Run it when the source list is updated:
#
#   ruby tools/make_known_game_codes.rb [path/to/gba_games.json]
#
# The source is a serial-keyed catalogue in the No-Intro naming convention
# ("AGB-AXVE" => "Pokemon - Ruby Version (USA)"). Only the codes are kept — the names
# are nobody's to copy, and the check does not need them.
module MakeKnownGameCodes
  DEFAULT_SOURCE = File.expand_path("~/open_source/gemba/src/gemba/data/gba_games.json")
  OUT = File.expand_path("../lib/ruby_gba/data/known_game_codes.txt", __dir__)

  def self.run(source = DEFAULT_SOURCE)
    unless File.file?(source)
      raise "I cannot read #{source}. Pass the catalogue's path as an argument: " \
            "ruby tools/make_known_game_codes.rb path/to/gba_games.json"
    end

    # A handful of entries carry the maker code on the end ("AGB-BMVE01"), so take
    # the four the cartridge header actually holds.
    codes = JSON.parse(File.read(source)).keys
                .map { |serial| serial.sub(/\AAGB-/, "")[0, 4].to_s }
                .select { |code| code.match?(/\A[A-Z0-9]{4}\z/) }
                .uniq
                .sort

    File.write(OUT, "#{codes.join("\n")}\n")
    puts "wrote #{codes.size} codes to #{OUT} (#{File.size(OUT)} bytes)"
  end
end

MakeKnownGameCodes.run(*ARGV) if $PROGRAM_NAME == __FILE__
