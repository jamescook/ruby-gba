# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # PUTS THE SECTIONS IN THE CARTRIDGE AND FILLS IN THE PLACES THEY NAME.
        #
        # The processor can only see 64K of addresses at once, and the cartridge is far bigger
        # than that, so it is cut into BANKS of 16K. Bank 0 is always in view, at 0x0000 to
        # 0x3FFF; any one of the others is in view at 0x4000 to 0x7FFF, whichever the game last
        # asked the cartridge's memory bank controller for. So a section is either FIXED — in bank
        # 0, which is where the runtime goes, since everything has to be able to call it — or
        # BANKED, in one of the others, and a jump from one bank to another is not a jump at all
        # but a call through bank 0 that switches the bank in view first (see Runtime#far_call).
        #
        # A section's +home+ says which: :fixed, :banked, :aligned16 (banked, starting at an address
        # that is a multiple of 16, which the console's copy into picture memory reads from), a
        # number (the address in bank 0 it must start at, for the processor's own entry points), or
        # a label, which puts it in the same bank as the section that defines that label, so it can
        # be jumped to directly.
        class Linker
          BANK_SIZE = 0x4000
          BANKED_START = 0x4000

          # A label's place: which bank, and the address the processor sees it at.
          Place = Data.define(:bank, :address)

          # The finished cartridge: its banks, every label's place, and every section's.
          Linked = Data.define(:banks, :places, :sections) do
            def address_of(label) = places.fetch(label.to_s).address
            def bank_of(label) = places.fetch(label.to_s).bank

            # The cartridge's bytes, every bank in order.
            def bytes = banks.join
          end

          # Raised for a fault of the lowering's own: two sections on one place, a label defined
          # twice, a jump that cannot reach. Nothing the author wrote can mend it.
          class Error < StandardError; end

          # Raised when the GAME is more than the cartridge has room for: its tables, songs or
          # pictures too big for the part always in view, or one of them bigger than a bank. It is
          # the game's to fix, so it is a refusal like the lowering's others (see Memory::Full),
          # and it names the game's parts by what they are, never by the sections they went in.
          class TooBig < LoweringError; end

          # ...the part always in view too full, which a game can mend by keeping its songs' notes in
          # the banks, and then its sprites' tables of poses in each list (GBC#build).
          class TooBigForView < TooBig; end

          # Where each section went: its bank and the address of its first byte.
          Placed = Data.define(:section, :bank, :address)

          # +fixed_from+ is the first address in bank 0 that sections without an address of their own
          # may use: past the cartridge's header, which the cartridge writes once everything is placed.
          # +clock+ is a cartridge with a clock chip, which has fewer banks (MOST_CLOCK_BANKS).
          def initialize(sections, fixed_from: 0, clock: false)
            @sections = sections
            @fixed_from = fixed_from
            @clock = clock
            @most_banks = clock ? MOST_CLOCK_BANKS : MOST_BANKS
          end

          def link
            placed = place_sections
            places = label_places(placed)
            banks = fill_banks(placed, places)
            Linked.new(banks: banks, places: places, sections: placed.to_h { |p| [p.section.name, p] })
          end

          private

          def place_sections
            placed = []
            fixed_free = BANK_SIZE
            # The processor's entry points first, at the addresses they must be at; then everything
            # else that must be in view all the time, after them.
            at_addresses, rest = @sections.partition { |section| section.home.is_a?(Integer) }
            at_addresses.sort_by(&:home).each do |section|
              placed << Placed.new(section: section, bank: 0, address: section.home)
            end
            next_fixed = [*at_addresses.map { |s| s.home + s.bytes.bytesize }, @fixed_from].max
            fixed, banked = rest.partition { |section| section.home == :fixed }
            fixed.each do |section|
              placed << Placed.new(section: section, bank: 0, address: next_fixed)
              next_fixed += section.bytes.bytesize
            end
            refuse_too_big_for_view!(placed, next_fixed) if next_fixed > fixed_free

            place_banked(placed, banked)
            refuse_overlaps!(placed)
            placed
          end

          # First fit, in the order the sections came: each goes in the first bank with room for
          # it, a section kept with another's label going in that one's bank.
          def place_banked(placed, banked)
            room = [] # bank number - 1 -> bytes used
            label_bank = {}
            placed.each { |p| p.section.labels.each_key { |l| label_bank[l] = p.bank } }
            banked.each do |section|
              size = section.size
              refuse_bigger_than_bank!(section) if size > BANK_SIZE

              align = section.home == :aligned16 ? 16 : 1
              start_in = ->(b) { ((room[b - 1] || 0) + align - 1) / align * align }
              bank = if section.home.is_a?(String)
                       label_bank.fetch(section.home) { raise Error, "section #{section.name} keeps with #{section.home}, which is not placed yet" }
                     else
                       (1..).find { |b| start_in.call(b) + size <= BANK_SIZE }
                     end
              refuse_too_many_banks!(banked) if bank >= @most_banks
              used = start_in.call(bank)
              raise Error, "section #{section.name} does not fit in bank #{bank} beside what is there" if used + size > BANK_SIZE

              placed << Placed.new(section: section, bank: bank, address: BANKED_START + used)
              room[bank - 1] = used + size
              section.labels.each_key { |l| label_bank[l] = bank }
            end
          end

          # HOW MANY BANKS A CARTRIDGE HAS AT MOST, as this one is driven. The cartridge's memory bank
          # controller (an MBC5) can switch between 512, but the runtime only ever writes the low
          # eight bits of the bank number, so bank 256 would come up as bank 0. A game that needs
          # more is refused here rather than built with jumps that land in the wrong bank.
          MOST_BANKS = 256

          # A CARTRIDGE WITH A CLOCK CHIP has the memory bank controller the console's own games with
          # a clock carried, an MBC3, which takes seven bits of the bank number: 128 banks, 2M.
          MOST_CLOCK_BANKS = 128

          DOES_NOT_FIT = "This game does not fit in a Game Boy Color cartridge."

          # The part always in view holds the runtime and everything the game reads while it runs
          # without switching a bank in: its tables of numbers, its songs, what its pictures are
          # made of. +needed+ is how far it came to. It is the game's to fix only when the
          # framework's own code would fit there on its own; a part always in view that the
          # framework fills by itself is the framework's fault, and stays an internal error.
          def refuse_too_big_for_view!(placed, needed)
            own = needed - placed.select { |p| p.section.holds }.sum { |p| p.section.size }
            raise Error, "the part of the cartridge always in view is #{needed} bytes, over #{BANK_SIZE}" if own > BANK_SIZE

            raise TooBigForView, "#{DOES_NOT_FIT} The part of the cartridge that is always in view holds #{BANK_SIZE} " \
                                 "bytes. The game needs #{needed} bytes there. Of those, " \
                                 "#{taken_words(placed.map(&:section))}, and the framework's own code takes the rest. " \
                                 "To fix this, #{biggest(placed.map(&:section)).fix}."
          end

          # One section bigger than a bank, which no placing can mend: the game's, when it is one of
          # the game's parts, and the framework's own fault otherwise.
          def refuse_bigger_than_bank!(section)
            raise Error, "section #{section.name} is #{section.size} bytes, more than a bank holds" unless section.holds

            raise TooBig, "#{DOES_NOT_FIT} A bank of the cartridge holds #{BANK_SIZE} bytes, and part of " \
                          "#{section.holds.what} needs #{section.size} bytes in one bank. To fix this, " \
                          "#{section.holds.fix}."
          end

          # More of the game than every bank of the cartridge holds together.
          def refuse_too_many_banks!(banked)
            raise Error, "the framework's own code needs more than #{@most_banks} banks" if banked.none?(&:holds)

            raise TooBig, "#{DOES_NOT_FIT} A cartridge#{' with a clock chip' if @clock} holds #{@most_banks} banks " \
                          "of #{BANK_SIZE} bytes. Of what goes in them, #{taken_words(banked)}. To fix this, " \
                          "#{biggest(banked).fix}."
          end

          # Bytes taken by each of the game's parts among +sections+, the biggest first.
          def game_parts(sections)
            sections.select(&:holds).group_by(&:holds).transform_values { |parts| parts.sum(&:size) }
                    .reject { |_, bytes| bytes.zero? }.sort_by { |_, bytes| -bytes }
          end

          # "the game's tables take 900 bytes and the game's songs take 40 bytes"
          def taken_words(sections)
            shares = game_parts(sections).map { |holding, bytes| "#{holding.what} take #{bytes} bytes" }
            shares.length == 1 ? shares.first : "#{shares[0...-1].join(', ')} and #{shares.last}"
          end

          # The game's biggest part among +sections+: the one worth making smaller.
          def biggest(sections) = game_parts(sections).first.first

          def refuse_overlaps!(placed)
            placed.group_by(&:bank).each_value do |in_bank|
              in_bank.sort_by(&:address).each_cons(2) do |a, b|
                next if a.address + a.section.bytes.bytesize <= b.address

                raise Error, "sections #{a.section.name} and #{b.section.name} overlap"
              end
            end
          end

          def label_places(placed)
            places = {}
            placed.each do |p|
              p.section.labels.each do |label, offset|
                raise Error, "label #{label} is defined twice" if places.key?(label)

                places[label] = Place.new(bank: p.bank, address: p.address + offset)
              end
            end
            places
          end

          def fill_banks(placed, places)
            count = [placed.map(&:bank).max + 1, 2].max
            banks = Array.new(count) { ("\xFF".b * BANK_SIZE) }
            placed.each do |p|
              bytes = p.section.bytes.dup
              p.section.fixups.each { |fixup| patch(bytes, fixup, p, places) }
              start = p.address - (p.bank.zero? ? 0 : BANKED_START)
              banks[p.bank][start, bytes.bytesize] = bytes
            end
            banks
          end

          def patch(bytes, fixup, placed, places)
            target = places.fetch(fixup.label) do
              raise Error, "#{placed.section.name} names #{fixup.label}, which no section defines"
            end
            value = target.address + fixup.plus
            case fixup.kind
            when :word, :near
              refuse_unreachable!(fixup, placed, target) if fixup.kind == :near
              bytes.setbyte(fixup.offset, value & 0xFF)
              bytes.setbyte(fixup.offset + 1, (value >> 8) & 0xFF)
            when :relative
              refuse_unreachable!(fixup, placed, target)
              distance = value - (placed.address + fixup.offset + 1)
              raise Error, "#{placed.section.name}: JR to #{fixup.label} is #{distance} bytes away, more than 127" unless distance.between?(-128, 127)

              bytes.setbyte(fixup.offset, distance & 0xFF)
            when :bank
              bytes.setbyte(fixup.offset, target.bank)
            end
          end

          # A jump or call reaches what is in view: bank 0, and the bank it is in itself.
          def refuse_unreachable!(fixup, placed, target)
            return if target.bank.zero? || target.bank == placed.bank

            raise Error, "#{placed.section.name} (bank #{placed.bank}) jumps to #{fixup.label} in bank #{target.bank}, " \
                         "which is not in view from there"
          end
        end
      end
    end
  end
end
