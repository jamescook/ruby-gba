# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHERE EVERYTHING GOES IN THE CARTRIDGE, and the holes the assembler left filled in.
        #
        # A Super Nintendo cartridge laid out the LoROM way is seen by the processor as banks of
        # 32K: bank $80 holds the cartridge's first 32K at addresses $8000 to $FFFF, bank $81 the
        # next 32K, and so on. (The lower half of each of those banks is the console's own: work
        # RAM, the picture and sound chips' registers.) Banks $80 and up are the FAST copy of the
        # cartridge — the same bytes as banks $00 and up, read a third faster once the cartridge
        # says it can keep up (Console::SNESHardware::MEMSEL) — so everything is placed there.
        #
        # Each section goes whole into one bank, since the processor cannot run off the end of a
        # bank into the next: the program counter goes round to the start of the same bank. A call
        # to another bank is a long one (JSL, and RTL back), and a table in another bank is read
        # with a long address, so nothing has to switch banks the way a Game Boy's bank
        # controller does. The first bank holds the sections that must be there: where the
        # processor starts and where its interrupts land, which the vectors at the end of that bank
        # name with 16-bit addresses. Its last 80 bytes are the cartridge's header and the vectors
        # (Cartridge::SNESROM).
        class Linker
          BANK_SIZE = 0x8000
          FIRST_BANK = 0x80 # the fast copy of the cartridge's first 32K
          ORIGIN = 0x8000 # where a bank's 32K start in the processor's view
          HEADER_FROM = 0x7FB0 # the first bank's header and vectors, written by the cartridge
          MOST_BANKS = 128 # four megabytes, as large as a LoROM cartridge's header can say

          # Where each label went: its 24-bit address.
          Linked = Data.define(:banks, :places, :sections) do
            def address_of(label) = places.fetch(label.to_s)
            def bytes = banks.join
          end

          class Error < StandardError; end

          # Raised when the GAME is more than the cartridge has room for. It names the game's parts by
          # what they are, never by the sections they went in.
          class TooBig < LoweringError; end

          # Where each section went: its bank (0 for the cartridge's first 32K) and offset in it.
          Placed = Data.define(:section, :bank, :offset) do
            def address = ((FIRST_BANK + bank) << 16) | (ORIGIN + offset)
          end

          DOES_NOT_FIT = "This game does not fit in a Super Nintendo cartridge."

          def initialize(sections)
            @sections = sections
          end

          def link
            placed = place_sections
            places = label_places(placed)
            banks = fill_banks(placed, places)
            Linked.new(banks: banks, places: places, sections: placed.to_h { |p| [p.section.name, p] })
          end

          private

          def place_sections
            used = [0]
            first, rest = @sections.partition { |section| section.home == :first }
            placed = first.map do |section|
              offset = used[0]
              used[0] += section.size
              Placed.new(section: section, bank: 0, offset: offset)
            end
            refuse_first_bank_full!(first) if used[0] > HEADER_FROM
            rest.each do |section|
              refuse_bigger_than_bank!(section) if section.size > BANK_SIZE
              bank = used.each_index.find { |i| used[i] + section.size <= room(i) }
              unless bank
                used << 0
                bank = used.size - 1
              end
              refuse_too_many_banks!(rest) if bank >= MOST_BANKS
              placed << Placed.new(section: section, bank: bank, offset: used[bank])
              used[bank] += section.size
            end
            placed
          end

          def room(bank) = bank.zero? ? HEADER_FROM : BANK_SIZE

          def refuse_first_bank_full!(first)
            raise Error, "the sections that must be in the first bank take #{first.sum(&:size)} bytes, over #{HEADER_FROM}"
          end

          def refuse_bigger_than_bank!(section)
            raise Error, "section #{section.name} is #{section.size} bytes, more than a bank holds" unless section.holds

            raise TooBig, "#{DOES_NOT_FIT} A bank of the cartridge holds #{BANK_SIZE} bytes, and part of " \
                          "#{section.holds.what} needs #{section.size} bytes in one bank. To fix this, " \
                          "#{section.holds.fix}."
          end

          def refuse_too_many_banks!(sections)
            raise Error, "the framework's own code needs more than #{MOST_BANKS} banks" if sections.none?(&:holds)

            parts = sections.select(&:holds).group_by(&:holds).transform_values { |s| s.sum(&:size) }
                            .sort_by { |_, bytes| -bytes }
            taken = parts.map { |holding, bytes| "#{holding.what} take #{bytes} bytes" }.join(", ")
            raise TooBig, "#{DOES_NOT_FIT} A cartridge holds #{MOST_BANKS} banks of #{BANK_SIZE} bytes. Of what " \
                          "goes in them, #{taken}. To fix this, #{parts.first.first.fix}."
          end

          def label_places(placed)
            placed.each_with_object({}) do |p, places|
              p.section.labels.each do |label, offset|
                raise Error, "label #{label} is defined twice" if places.key?(label)

                places[label] = p.address + offset
              end
            end
          end

          def fill_banks(placed, places)
            count = placed.map(&:bank).max.to_i + 1
            banks = Array.new(count) { ("\xFF".b * BANK_SIZE) }
            placed.each do |p|
              bytes = p.section.bytes.dup
              p.section.fixups.each { |fixup| patch(bytes, fixup, p, places) }
              banks[p.bank][p.offset, bytes.bytesize] = bytes
            end
            banks
          end

          def patch(bytes, fixup, placed, places)
            target = places.fetch(fixup.label) do
              raise Error, "#{placed.section.name} names #{fixup.label}, which no section defines"
            end
            target += fixup.plus
            case fixup.kind
            when :abs then bytes[fixup.offset, 2] = [target & 0xFFFF].pack("v")
            when :long then bytes[fixup.offset, 3] = [target & 0xFFFF, (target >> 16) & 0xFF].pack("vC")
            when :bank then bytes.setbyte(fixup.offset, (target >> 16) & 0xFF)
            when :relative then patch_relative(bytes, fixup, placed, target, 1, -128..127, "c")
            when :relative_long then patch_relative(bytes, fixup, placed, target, 2, -32_768..32_767, "s<")
            else raise Error, "unknown fixup #{fixup.kind}"
            end
          end

          # A branch's distance is counted from the instruction after it, and stays in its bank.
          def patch_relative(bytes, fixup, placed, target, size, range, pack)
            from = placed.address + fixup.offset + size
            if (target >> 16) != (from >> 16)
              raise Error, "#{placed.section.name} branches to #{fixup.label}, which is in another bank"
            end

            distance = target - from
            unless range.cover?(distance)
              raise Error, "#{placed.section.name}: a branch to #{fixup.label} is #{distance} bytes away, " \
                           "more than #{range.max}"
            end

            bytes[fixup.offset, size] = [distance].pack(pack)
          end
        end
      end
    end
  end
end
