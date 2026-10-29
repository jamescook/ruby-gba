# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # THE PIECES A CARTRIDGE IS PUT TOGETHER FROM, the same for every console whose cartridge is
      # seen a bank at a time. An assembler (GBC::SM83, SNES::W65816) makes SECTIONS: named runs of
      # bytes, with the labels they define and the holes they leave for places not known yet (a
      # Fixup). A linker (GBC::Linker, SNES::Linker) puts each section in a bank of the cartridge
      # (Banks), then fills the holes in. Which instructions a section holds, how big a bank is and
      # how a hole is filled are the console's; what a section is, how the banks fill up and how a
      # cartridge too full for the game says so are decided here.
      module Sections
        # A place named in an instruction, filled in once everything is placed. Which +kind+s there
        # are is the assembler's own: each says what it fills in (an address, a distance, a bank).
        Fixup = Data.define(:offset, :kind, :label, :plus)

        # A named run of bytes, with the labels it defines and the holes it leaves. +home+ says where
        # it must go, in the words of the console's linker. +holds+ is what of the GAME's it keeps (a
        # Holding), so a cartridge too full for the game can say which of the game's parts is too big
        # and how to make it smaller; nil for the framework's own code, which is not the author's to
        # change.
        Section = Data.define(:name, :bytes, :labels, :fixups, :home, :holds) do
          def size = bytes.bytesize
        end

        # One of the game's parts, in words the author knows: +what+ it is ("the game's songs",
        # always plural, since it is said as "the game's songs take 900 bytes"), and +fix+, what the
        # author can do to make it smaller ("make its songs shorter, or use fewer of them").
        Holding = Data.define(:what, :fix)

        # THE BANKS, FILLED FIRST FIT. Each section goes in the first bank, counting from +first+,
        # with room for it after what is already there; a bank holds what +room+ says it does (a
        # bank's last bytes can be the cartridge's own, as the Super Nintendo's first bank's header
        # is). A section that must start at a multiple of +align+ skips the bytes up to the next one.
        class Banks
          def initialize(first:, room:)
            @first = first
            @room = room
            @used = Hash.new(0)
          end

          # The first bank +size+ bytes fit in, starting at a multiple of +align+. Nothing is taken.
          def first_fit(size, align: 1) = (@first..).find { |bank| start_in(bank, align) + size <= @room.call(bank) }

          # Where in +bank+ +size+ bytes starting at a multiple of +align+ go, taken, or nil when
          # they do not fit beside what is there.
          def take(bank, size, align: 1)
            start = start_in(bank, align)
            return nil if start + size > @room.call(bank)

            @used[bank] = start + size
            start
          end

          private

          def start_in(bank, align) = (@used[bank] + align - 1) / align * align
        end

        # The bytes each of the game's parts takes among +sections+, the biggest first.
        def self.game_parts(sections)
          sections.select(&:holds).group_by(&:holds).transform_values { |parts| parts.sum(&:size) }
                  .reject { |_, bytes| bytes.zero? }.sort_by { |_, bytes| -bytes }
        end

        # What the game's parts among +sections+ take, in words: "the game's tables take 900 bytes
        # and the game's songs take 40 bytes".
        def self.taken_words(sections)
          shares = game_parts(sections).map { |holding, bytes| "#{holding.what} take #{bytes} bytes" }
          shares.length == 1 ? shares.first : "#{shares[0...-1].join(', ')} and #{shares.last}"
        end

        # The game's biggest part among +sections+: the one worth making smaller.
        def self.biggest(sections) = game_parts(sections).first.first
      end
    end
  end
end
