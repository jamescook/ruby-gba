# frozen_string_literal: true

module RubyGBA
  # WHAT WENT IN THE OTHER MEMORY.
  #
  # A console can have more than one work memory, and they are not two sizes of the same
  # thing: one is small, on the processor's own die, and answers at once; the other is
  # large, on a chip of its own, and makes the processor wait. Everything a program
  # declares goes in the quick one until it will not fit, and then the coldest collections
  # fall into the roomy one — which is a decision nobody wrote and nothing else can show.
  #
  # It matters twice over. Once because a game that used to fail to build now builds. And
  # once because the quick memory is ALSO where the hot code is kept, so a big cold
  # collection sitting there quietly pushes a routine the frame spends its time in out to
  # the cartridge, where it runs about two and a third times slower. Seeing what landed
  # where is what lets an author say `fast: false` about the one that should move.
  RoomyMemory = Data.define(:used, :free, :collections) do
    def total = used + free

    def to_h
      { used: used, free: free, total: total,
        collections: collections.map { |name, bytes| { name: name.to_s, bytes: bytes } } }
    end
  end
end
