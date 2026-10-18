# frozen_string_literal: true

module RubyGBA
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
        # A section's +home+ says which: :fixed, :banked, a number (the address in bank 0 it must
        # start at, for the processor's own entry points), or a label, which puts it in the same
        # bank as the section that defines that label, so it can be jumped to directly.
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

          class Error < StandardError; end

          # Where each section went: its bank and the address of its first byte.
          Placed = Data.define(:section, :bank, :address)

          # +fixed_from+ is the first address in bank 0 that sections without an address of their own
          # may use: past the cartridge's header, which the cartridge writes once everything is placed.
          def initialize(sections, fixed_from: 0)
            @sections = sections
            @fixed_from = fixed_from
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
            raise Error, "the part of the cartridge always in view is #{next_fixed} bytes, over #{BANK_SIZE}" if next_fixed > fixed_free

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
              size = section.bytes.bytesize
              raise Error, "section #{section.name} is #{size} bytes, more than a bank holds" if size > BANK_SIZE

              bank = if section.home.is_a?(String)
                       label_bank.fetch(section.home) { raise Error, "section #{section.name} keeps with #{section.home}, which is not placed yet" }
                     else
                       (1..).find { |b| (room[b - 1] || 0) + size <= BANK_SIZE }
                     end
              used = room[bank - 1] || 0
              raise Error, "section #{section.name} does not fit in bank #{bank} beside what is there" if used + size > BANK_SIZE

              placed << Placed.new(section: section, bank: bank, address: BANKED_START + used)
              room[bank - 1] = used + size
              section.labels.each_key { |l| label_bank[l] = bank }
            end
          end

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
