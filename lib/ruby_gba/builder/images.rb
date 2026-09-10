# frozen_string_literal: true

module RubyGBA
  class Builder
    # The image + color verbs: define a bitmap (from raw data, a file, or ASCII
    # art), draw it with blit, and build colors (rgb/rgb8/color). A concern of
    # {Builder}, mixed in so these stay flat DSL verbs.
    module Images
      # The unused 16th bit of a BGR555 color, set to mark a pixel transparent — a
      # real color is 0x0000..0x7FFF, so this can never collide with one.
      TRANSPARENT_PIXEL = 0x8000

      # Define a bitmap, two ways.
      #
      # Array form — raw pixel data, the shape the importer produces. +data+ is
      # width*height colors (names, hex strings, or raw BGR555 integers), row-major:
      #
      #   image :friend, width: 16, height: 16, data: bmp.data
      #
      # From-a-file form — hand it an image on your machine and a size, and it's
      # imported (via RubyGBA::Image) and embedded in one step:
      #
      #   image :friend, from: "friend.png", width: 16, height: 16
      #
      # Add transparent: true for a cut-out (an image with its background removed):
      # the removed areas become see-through, so the game field shows through them
      # instead of a rectangle.
      #
      #   image :friend, from: "cutout.png", width: 16, height: 16, transparent: true
      #
      # It works for the array form too, where a pixel written as :transparent is the
      # see-through one:
      #
      #   image :things, width: 64, height: 64, data: pixels, transparent: true
      #
      # ASCII-art form — hand-drawn, with a char=>color map and a block of art. The
      # dimensions come from the art's shape, and one char may map to :transparent
      # (those pixels aren't drawn, so the background shows through):
      #
      #   image :ship, "." => :transparent, "#" => :cyan, "*" => :red do
      #     <<~ART
      #       ..#..
      #       .#*#.
      #       #####
      #     ART
      #   end
      #
      # Either way the pixels are packed to 15-bit color and embedded in the ROM; a
      # later `blit` draws it by name.
      # +opts+ is a single trailing hash — the char=>color map (ASCII form, with a
      # block), width:/height:/data: (array form), or from:/width:/height: (file
      # form). It's positional, not keywords, so the char map's string keys (like
      # "#") pass through cleanly.
      # Add colors: [...] for art that came from somewhere that already decided its
      # colors — a picture pulled out of another game, or one an artist drew against a
      # fixed set. The list is that set, in its own order, see-through first:
      #
      #   image :link, from: "link.png", colors: [:transparent, :white, :green, ...]
      #
      # Say it and the framework keeps that order rather than working one out. Say
      # nothing, which is almost always right, and it works one out from the colors in
      # the art.
      def image(name, opts = {}, &block)
        if block
          define_ascii_image(name, opts, &block)
        elsif opts[:from]
          bmp = Image.load(resolve_asset_path(opts[:from]), width: opts[:width], height: opts[:height],
                                                            transparent: opts.fetch(:transparent, false))
          define_pixel_image(name, width: bmp.width, height: bmp.height, data: bmp.data,
                                   transparent: bmp.transparent, colors: opts[:colors])
        else
          define_pixel_image(name, width: opts[:width], height: opts[:height], data: opts[:data],
                                   transparent: opts[:transparent], colors: opts[:colors])
        end
      end

      # Draw a bitmap (defined with `image`) at a position, which may be a variable
      # (a moving object) or a constant. Keep it on-screen — off-screen parts aren't
      # clipped at run time yet.
      #
      # @example
      #   blit :friend, :ball_x, :ball_y
      #
      # ONE OF A SET, picked by a number the game works out: give it the pictures and
      # say what chooses between them.
      #
      #   blit [:calm, :hurt, :dying], 100, 4, showing: damage
      #
      # A face that watches you, a machine in four stages of wreckage, a dial drawn as a
      # strip, a portrait picked by who is speaking. `showing:` is the same word a menu
      # row and a two-colour label already use for "this value decides which". The
      # pictures must all be the same size, and a number outside the set draws nothing —
      # so a value still settling, or one that ran off the end, leaves the screen alone
      # rather than drawing the wrong picture.
      def blit(name, x, y, showing: nil)
        return blit_one_of(name, x, y, showing) if name.is_a?(Array)

        unless showing.nil?
          raise ArgumentError,
                "blit :#{name} was given showing:, but it draws one picture. showing: picks between " \
                "several, so give it a list: blit [:#{name}, :other], #{x}, #{y}, showing: ..."
        end
        record(Build.blit(name, Value.node_for(x), Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
      end

      # THE SAME PICTURE FACING THE OTHER WAY, without drawing it twice.
      #
      #   sprite :hero, at: [100, 60],
      #          facing: { right: :hero_right, left: mirror(:hero_right) }
      #
      # "Left is the right one, backwards" is how nearly every 2D game faces a
      # character, and until now saying it meant drawing the art twice — or exporting
      # it twice, for art that came from somewhere else. This hands back a picture
      # name like any other, so it drops into `facing:`, `frames:`, a `pool`, or a
      # plain `blit` wherever a picture name goes.
      #
      # A whole animation turns round in one go: pass the list and get a list back.
      #
      #   WALK = [:walk_r1, :walk_r2, :walk_r3]
      #   sprite :hero, at: [100, 60], rate: 6,
      #          facing: { right: WALK, left: mirror(WALK) }
      #
      # ON `screen :tiled` A MIRRORED POSE COSTS NO SPRITE MEMORY. The console can
      # draw an object reversed for nothing, so the build stores the picture once and
      # says "that one, backwards" — a third off a character that faces both ways.
      # (It notices art that is ALREADY a mirror too, so a game that drew both ways by
      # hand gets the same saving with nothing to change. On `screen :bitmap` there is
      # no such hardware, so a mirrored picture is drawn like any other: this saves you
      # the art, not the memory.)
      #
      # @param names [Array<Symbol>] one picture name, several, or a list of them
      # @return [Symbol, Array<Symbol>] a name for one, a list of names for several
      def mirror(*names)
        one = names.length == 1 && !names.first.is_a?(Array)
        turned = names.flatten.map { |source| mirrored_image(source) }
        one ? turned.first : turned
      end

      # Pack 5-bit RGB channels (0-31 each) into a 15-bit GBA color.
      # Raises on out-of-range values to catch mistakes early.
      def rgb(r, g, b)
        Color.rgb(r, g, b)
      end

      # Pack 8-bit RGB channels (0-255 each) into a 15-bit GBA color.
      # Automatically downsamples to 5-bit per channel.
      def rgb8(r, g, b)
        Color.rgb8(r, g, b)
      end

      # Resolve a color from a name, hex string, or raw value.
      def color(value)
        Color.resolve(value)
      end

      private

      # Record a picture's declaration and everything the rest of the build asks about
      # it: its shape, so a sprite can size itself from its art, and its pixels, so
      # `mirror` can turn it round.
      def remember_picture(node)
        record(node)
        @pictures[node.name] = IR::Assets::Image.of(node)
        @images[node.name] = [node.width, node.height]
      end

      # The mirror of one picture, made the first time it is asked for and handed back
      # after that — so mirroring the same art from two sprites makes one picture, not
      # two. Its visible-pixel box turns round with it, so a character built this way
      # collides on the art facing either way.
      def mirrored_image(source)
        @mirrored_images[source] ||= begin
          picture = @pictures[source] ||
                    raise(ArgumentError,
                          "mirror names the picture :#{source}, which is not defined. Define it first " \
                          "with `image :#{source}, ...`.")
          name = free_mirror_name(source)
          turned = picture.mirrored
          remember_picture(Build.bitmap(name, width: turned.width, height: turned.height,
                                              pixels: turned.pixels, transparent: turned.transparent,
                                              colors: turned.colors))
          box_x, box_y, box_w, box_h = @image_bounds[source] || [0, 0, turned.width, turned.height]
          @image_bounds[name] = [turned.width - box_x - box_w, box_y, box_w, box_h]
          name
        end
      end

      # A name for the mirror that reads like the picture it came from, and that no
      # other picture has already taken.
      def free_mirror_name(source)
        return :"#{source}_mirrored" unless @images.key?(:"#{source}_mirrored")

        (2..).lazy.map { |n| :"#{source}_mirrored#{n}" }.find { |name| !@images.key?(name) }
      end

      # Draw whichever of +names+ the +showing+ value picks. Written the long way this is
      # a test and a draw per picture, which is what it lowers to anyway — so this is the
      # same work said once, and both backends already know how to do it.
      def blit_one_of(names, x, y, showing)
        if showing.nil?
          raise ArgumentError,
                "blit was given #{names.length} pictures and nothing to pick between them. Say which " \
                "one to draw with showing:, like blit [:#{names.first}, ...], #{x}, #{y}, showing: state."
        end
        raise ArgumentError, "blit was given an empty list of pictures. Name at least one." if names.empty?

        same_size_blit!(names)
        record(Build.blit_pose(names, Value.node_for(showing), Value.node_for(x), Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
        ensure_var(showing)
      end

      # Pictures picked between must all be the same size: one is drawn where the last
      # one was, so a smaller one would leave the edges of a bigger one behind.
      def same_size_blit!(names)
        sizes = names.to_h do |picture|
          size = @images[picture] or
            raise ArgumentError,
                  "blit names the picture :#{picture}, which is not defined. Define it first with " \
                  "`image :#{picture}, ...`."
          [picture, size]
        end
        return if sizes.values.uniq.length == 1

        common = sizes.values.tally.max_by { |_size, count| count }.first
        odd = sizes.find { |_picture, size| size != common }
        raise ArgumentError,
              "blit picks between pictures of different sizes. :#{odd.first} is " \
              "#{odd.last[0]}x#{odd.last[1]} and the others are #{common[0]}x#{common[1]}. " \
              "Pictures picked between must all be the same size."
      end

      # Array form of #image: validate the dimensions and pack the pixel colors.
      # +transparent+ (an internal marker color, e.g. from an imported cutout) is
      # left untouched while every other pixel is resolved — otherwise resolving it
      # would mask the marker away — and it's recorded on the bitmap so `blit`
      # skips those pixels, letting the background show through.
      #
      # `transparent: true` is the same thing said the way the art form says it:
      # pixels written as :transparent are see-through and everything else is a
      # color. That's for art a program builds itself — pictures converted out of
      # some other game's files, say — which arrives as an array rather than as
      # rows of characters, and otherwise had to know the marker color's value.
      def define_pixel_image(name, width:, height:, data:, transparent: nil, colors: nil)
        positive_dims!(name, width, height)
        expected = width * height
        unless data.length == expected
          raise ArgumentError,
                "image :#{name} is #{width}x#{height}, so it needs #{expected} pixels. Got #{data.length}."
        end

        transparent = TRANSPARENT_PIXEL if transparent == true
        data = data.map { |c| c == :transparent ? transparent : c } if transparent == TRANSPARENT_PIXEL
        pixels = data.map { |c| c == transparent ? transparent : Color.resolve(c) }.pack("v*")
        given = own_colors(name, colors, pixels, transparent)
        remember_picture(Build.bitmap(name, width: width, height: height, pixels: pixels,
                                            transparent: transparent, colors: given))
        record_visible_bounds(name: name, width: width, height: height, cells: data, transparent: transparent)
      end

      # ASCII-art form of #image: split the block's art into rows, infer the size
      # from its shape, map each char to a color (or transparency), and pack it.
      def define_ascii_image(name, char_map)
        rows = yield.to_s.each_line.map(&:chomp).reject(&:empty?)
        raise ArgumentError, "image :#{name} has no art. Add art rows to the block." if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "image :#{name} has rows of different lengths (#{widths.sort.join(', ')} wide). Every row must be the same length."
        end

        transparent = false
        colors = rows.flat_map do |row|
          row.each_char.map do |ch|
            spec = char_map.fetch(ch) { raise ArgumentError, "image :#{name}: the character '#{ch}' has no color. Give '#{ch}' a color in the map." }
            if spec == :transparent
              transparent = true
              TRANSPARENT_PIXEL
            else
              Color.resolve(spec)
            end
          end
        end

        remember_picture(Build.bitmap(name, width: widths.first, height: rows.size,
                                            pixels: colors.pack("v*"),
                                            transparent: transparent ? TRANSPARENT_PIXEL : nil))
        record_visible_bounds(name: name, width: widths.first, height: rows.size, cells: colors, transparent: transparent ? TRANSPARENT_PIXEL : nil)
      end

      # How many colors a picture may be given, and how many of those a pixel may
      # actually be. A picture drawn from its own list has a see-through slot at the
      # front, which the console reads as "leave this pixel alone" whatever color sits
      # there — so it holds one fewer real color than its length.
      OWN_COLORS = 16

      # A picture's own table, checked while the author is still looking at the line
      # that wrote it. Three things can be wrong, and each is a plain sentence rather
      # than a number turning up later in a lowering pass:
      # too many colors, a pixel drawn in a color the list does not hold, and a pixel
      # sitting on the see-through slot (where it would vanish).
      def own_colors(name, colors, pixels, transparent)
        return nil if colors.nil?

        unless colors.length <= OWN_COLORS
          raise ArgumentError,
                "image :#{name} was given #{colors.length} colors. A picture drawn from its own list of " \
                "colors can have #{OWN_COLORS} of them, the first meaning see-through. Give it " \
                "#{OWN_COLORS} or fewer, or give it none and the framework works the list out."
        end

        table = colors.map { |c| c == :transparent ? nil : Color.resolve(c) }
        drawn = pixels.unpack("v*").uniq
        drawn.each do |value|
          next if transparent && value == transparent

          slot = table.index(value & 0x7FFF)
          raise ArgumentError, unlisted_color(name, value & 0x7FFF) if slot.nil?
          next unless slot.zero?

          raise ArgumentError,
                "image :#{name} draws with #{Color.name_for(value & 0x7FFF)}, which is first in its list of " \
                "colors. The first color in the list means see-through, so those pixels will not be drawn. " \
                "Put a see-through entry first and move this color after it."
        end
        table.map { |value| value || 0x0000 }
      end

      def unlisted_color(name, value)
        "image :#{name} draws with #{Color.name_for(value)}, which is not in the list of colors it was " \
          "given. A picture given `colors:` is drawn from those colors and no others. Add this one to " \
          "the list, or draw the picture with a color already in it."
      end

      # Remember the box around an image's visible (non-transparent) pixels, so a
      # sprite made from it collides on the art itself, not the empty margin around it.
      # +cells+ is the image's pixels row-major and +transparent+ the value that marks a
      # see-through one (nil if the image is fully opaque — then the box is the whole
      # image). A blank image (nothing but transparent) also falls back to the whole
      # image, so its collision box is never empty.
      def record_visible_bounds(name:, width:, height:, cells:, transparent:)
        if transparent.nil?
          @image_bounds[name] = [0, 0, width, height]
          return
        end

        min_x = width
        min_y = height
        max_x = -1
        max_y = -1
        height.times do |y|
          width.times do |x|
            next if cells[(y * width) + x] == transparent

            min_x = x if x < min_x
            max_x = x if x > max_x
            min_y = y if y < min_y
            max_y = y if y > max_y
          end
        end

        @image_bounds[name] = max_x.negative? ? [0, 0, width, height] : [min_x, min_y, max_x - min_x + 1, max_y - min_y + 1]
      end

      def positive_dims!(name, width, height)
        return if Whole.positive?(width) && Whole.positive?(height)

        raise ArgumentError, "image :#{name} needs a width and height above 0. Got #{width}x#{height}."
      end
    end
  end
end
