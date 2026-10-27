# frozen_string_literal: true

module VBlank
  module DSL
    # A RUN OF TILES THE GAME PAINTS ITSELF, handed back by `tiles :box, from: list, count: n`.
    #
    # The pixels live in the game's own list; this is how the game says they moved. Writing
    # into the list changes nothing on screen by itself, because the screen draws its tiles
    # out of video memory, not out of the list. `changed` asks for the list to be copied there
    # in the gap before the next frame, so the player never sees a picture half copied. Saying
    # it several times in one frame is still one copy, and saying it every frame copies every
    # frame — which is what a box typing a letter a frame wants.
    class TileRun
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # The list's pixels show on the next frame. With +now+ they are copied here, inside the
      # frame's own work, and show on this frame — the way a cartridge that writes straight
      # into video memory shows a letter typed on the frame the button was read. The price is
      # the one that cartridge pays: the Advance may be drawing the screen while the copy is
      # made, so for one frame the top of the picture can be old and the bottom new. (The
      # Color locks its video memory while it draws, so its lowering packs the list here and
      # puts it in between frames, in time for the same picture.)
      def changed(now: false)
        now ? @builder.emit_tile_copy_in_place(@name) : @builder.request_tile_copy(@name)
        nil
      end
    end
  end
end
