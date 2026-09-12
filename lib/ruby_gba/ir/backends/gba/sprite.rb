# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # EVERYTHING THE BUILD WORKED OUT ABOUT ONE SPRITE, for the drawing to read every frame.
        #
        # The console calls these OBJECTS, and so does the code around here (`@objects`, `obj`,
        # `prepare_one_object`) — the record is named for what the author wrote instead, because
        # `Object` is a name Ruby already has and shadowing it inside a namespace is a trap
        # nobody needs.
        #
        # It is built once, in GBA#prepare_one_object, and read in two files: this backend's own
        # sizing and error messages, and the drawing that emits the per-frame writes. Named
        # fields rather than a Hash because it has twenty-eight of them, most nil in the
        # ordinary case — the shape where a misspelling reads as nil and turns up as a black
        # screen a long way from the cause.
        #
        # WHAT THE FIELDS SAY, in the four groups a reader actually wants:
        #
        #   WHERE IT SITS   +slot+ is its first of the console's 128 places and +pieces+ how
        #                   many it takes (a picture too big to draw in one go is cut up, and
        #                   the pieces stand shoulder to shoulder). +scene+ names the scene that
        #                   owns it, or nothing for a sprite that is always there.
        #
        #   ITS PICTURES    +tiles+ is the blob of them and +tile_units+ its size in the 32-byte
        #                   units sprite memory counts in; +tile_index+ is where the first one
        #                   landed. +tiles+ is nil for a sprite that SHARES another's pictures,
        #                   which is why it is worth testing rather than assuming.
        #
        #   ITS POSES       +pose+ is the run-time selector and +pose_count+ how many there are.
        #                   +alike+ decides the whole draw: poses trimmed the same way sit an
        #                   even +per_pose+ apart and are found by multiplying, where poses that
        #                   came out different sizes (or that mirror another) carry a table
        #                   instead — +pose_table+ and +pose_words+, both nil when +alike+.
        #                   +mirrors+ says which poses are drawn backwards.
        #
        #   HOW IT IS DRAWN +x+, +y+, +active+, +angle+ and +scale+ are the live operands; the
        #                   +offset_x+/+offset_y+ pair is where the first pose sat inside the
        #                   canvas it was drawn on, added back so trimming does not move the
        #                   picture. The three +attr*_base+ words are everything about the sprite
        #                   that never changes, folded together at build time so a frame only
        #                   ORs in what does.
        #
        # THE ONE THAT WAS A SECRET IS +affine_slot+. A sprite that turns or resizes is drawn
        # through one of the console's 32 rotation/size parameter groups, and which group used
        # to be written INTO this record after it was built, by a different method — so the draw
        # read a field that nothing in the construction mentioned. It is handed in with the
        # sprite's place now, because it is the same kind of fact: something the build gives the
        # sprite, not something it discovers later. nil for a sprite that stays upright at its
        # drawn size, which is nearly all of them and costs nothing.
        Sprite = Data.define(
          :slot, :pieces, :scene,
          :tiles, :tile_units, :tile_index,
          :pose, :pose_count, :alike, :per_pose, :pose_table, :pose_words, :mirrors,
          :offset_x, :offset_y, :width, :height,
          :x, :y, :active, :angle, :scale, :transformed, :scales, :affine_slot,
          :attr0_base, :attr1_base, :attr2_base,
        )
      end
    end
  end
end
