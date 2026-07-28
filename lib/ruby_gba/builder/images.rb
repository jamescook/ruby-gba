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
      def image(name, opts = {}, &block)
        if block
          define_ascii_image(name, opts, &block)
        elsif opts[:from]
          bmp = Image.load(opts[:from], width: opts[:width], height: opts[:height],
                                        transparent: opts.fetch(:transparent, false))
          define_pixel_image(name, width: bmp.width, height: bmp.height, data: bmp.data,
                                   transparent: bmp.transparent)
        else
          define_pixel_image(name, width: opts[:width], height: opts[:height], data: opts[:data],
                                   transparent: opts[:transparent])
        end
      end

      # Import several images at once from a sheet — one PNG holding a grid of
      # equal-size pictures, the way art is usually drawn: a tile sheet, or a
      # sprite sheet of animation frames. You give the cell size and a name for
      # each cell you want; each becomes an ordinary `image`, so it drops straight
      # into `tiles`, `sprite`, or `blit` with no other change — an imported tile
      # and a hand-drawn one are interchangeable at the use site.
      #
      #   sheet "dungeon.png", tile: 8, as: { brick: [0, 0], floor: [1, 0], water: [2, 0] }
      #   tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
      #   background :room, tiles: :dungeon, map: MAP
      #
      # A cell is addressed by [column, row] (both from zero, left-to-right then
      # top-to-bottom) — or by a single number counting the same way, handy for a
      # one-row strip of animation frames:
      #
      #   sheet "hero.png", tile: 16, as: { stand: 0, step1: 1, step2: 2 }, transparent: true
      #   hero = sprite :hero, at: [x, y], frames: [:step1, :step2], rate: 8
      #
      # +transparent: true+ honors the sheet's cut-out background (for sprites that
      # shouldn't draw a box around themselves); leave it off for solid tiles.
      #
      # @param path [String] a sheet image on your machine (PNG, …)
      # @param tile [Integer, Array(Integer, Integer)] cell size — one number for a
      #   square, or [width, height]
      # @param as [Hash{Symbol=>Array(Integer,Integer), Integer}] image name => cell
      # @param transparent [Boolean] honor the sheet's transparency for cut-out cells
      # @return [Array<Symbol>] the names of the images it defined
      def sheet(path, tile:, as:, transparent: false)
        tile_w, tile_h = normalize_tile(tile)
        raise ArgumentError, "sheet #{path.inspect} needs at least one cell in as: { name => cell }" if as.empty?

        sliced = Image.slice(path, tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        as.each do |img_name, where|
          col, row = sheet_cell(img_name, where, sliced.cols)
          bmp = sliced.cell(col, row)
          define_pixel_image(img_name, width: bmp.width, height: bmp.height, data: bmp.data,
                                       transparent: bmp.transparent)
        end
        as.keys
      end

      # Draw a bitmap (defined with `image`) at a position, which may be a variable
      # (a moving object) or a constant. Keep it on-screen — off-screen parts aren't
      # clipped at run time yet.
      #
      # @example
      #   blit :friend, :ball_x, :ball_y
      def blit(name, x, y)
        record(Build.blit(name, Value.node_for(x), Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
      end

      # Make a sprite: a named image that moves around the screen leaving no trail.
      # It remembers the pixels underneath itself and paints them back when it moves,
      # and the framework redraws it for you each frame — so you never call a draw
      # verb or clear the screen. Returns a {Sprite} whose `x`/`y` you steer with the
      # ordinary expression DSL.
      #
      #   image :heart, "." => :transparent, "#" => :red do ... end
      #   clear_screen :blue           # paint the field ONCE, before the loop
      #   hero = sprite :heart, at: [100, 60]
      #   game_loop do
      #     wait_vblank
      #     held(:right).then { hero.x.add 2 }
      #   end
      #
      # Pass +shown: false+ for a sprite that starts hidden and appears later — a
      # boss, a power-up, a second player who joins mid-game. Its RAM is reserved up
      # front (there's no allocating memory mid-game on the console — you budget it
      # when the ROM is built), but nothing is drawn until you `show` it, and while
      # hidden the per-frame repaint skips it for almost nothing. So a late arrival
      # costs a little reserved memory, not a busy sprite:
      #
      #   boss = sprite :boss, at: [200, 40], shown: false
      #   game_loop do
      #     wait_vblank
      #     after(90, :seconds) { boss.show } # the boss turns up a minute and a half in
      #   end
      #
      # Give a sprite POSES so it can face the way it moves: pass +facing:+ a map of
      # direction to image (all the same size). The sprite then draws whichever pose
      # it's facing, and `move(:left)` (or `face(:left)`) turns it — the frame-swap
      # way 2D games face a character, done in bitmap mode:
      #
      #   pac = sprite :pac, at: [100, 60],
      #                facing: { right: :pac_right, left: :pac_left, up: :pac_up, down: :pac_down }
      #   held(:left).then { pac.move :left, by: 2 } # moves AND faces left
      #
      # The first entry is the pose it starts in. (This is pose-swapping, not pixel
      # rotation — turning to an arbitrary angle is the affine/hardware-sprite track.)
      #
      # The kind of sprite you get follows the screen you chose. On a `screen :bitmap`
      # it's a *software* sprite (it remembers and restores the pixels under itself,
      # as described above). On a `screen :tiled` it's a *hardware* sprite: the
      # console composites it over the background for you, so it costs no per-pixel
      # work and can stack cleanly over other sprites. The handle is the same either
      # way — `x`/`y`/`move`/`move_to` — so the game code doesn't change.
      #
      # Pass +frames:+ a list of same-size images and +rate:+ to make the sprite a
      # FLIPBOOK: the framework cycles through those frames — one every +rate+ frames —
      # with the timer hidden and managed for you, so a coin spins or a torch flickers
      # with nothing to drive by hand. It composes with movement (walk it with `move`
      # while it animates), and works the same on a `screen :bitmap` or `screen :tiled`.
      #
      #   spin = sprite :coin, at: [x, y], frames: [:coin1, :coin2, :coin3, :coin4], rate: 6
      #
      # +facing:+ and +frames:+ are two ways to drive the same pose, so a sprite takes
      # one or the other, not both.
      #
      # @param name [Symbol] a defined image (its size becomes the sprite's size), or
      #   just the sprite's identity when +facing:+ / +frames:+ supply the images
      # @param at [Array(Integer, Integer)] the sprite's starting [x, y]
      # @param facing [Hash{Symbol=>Symbol}, nil] direction => image, for a sprite that turns
      # @param frames [Array<Symbol>, nil] same-size images to cycle as an animation
      # @param rate [Integer, nil] frames-per-step for +frames:+ (required with it)
      # @param shown [Boolean] draw it now (true, default), or start hidden until `show`
      # @return [Sprite, HardwareSprite] a handle: x / y / move / move_to (and, in bitmap mode, face / hide / show)
      def sprite(name, at:, facing: nil, frames: nil, rate: nil, shown: true)
        validate_animation!(name, facing, frames, rate)
        return hardware_sprite(name, at: at, facing: facing, frames: frames, rate: rate, shown: shown) \
          if @screen_mode == :tiled

        poses, facing_dirs, width, height = resolve_sprite_art(name, facing, frames)
        has_poses = !poses.nil?
        start_x, start_y = at

        id = (@sprite_seq += 1)
        pos_x = :"__spr#{id}_x"
        pos_y = :"__spr#{id}_y"
        old_x = :"__spr#{id}_ox"
        old_y = :"__spr#{id}_oy"
        active = :"__spr#{id}_on"
        buffer = :"__spr#{id}_under"
        pose_var = (:"__spr#{id}_face" if has_poses) # the pose selector (a facing or a frame)

        # Hidden state, set at boot (console RAM isn't zero at power-on): the current
        # and last-drawn positions both start at `at`, the on/off flag records
        # whether the sprite starts visible, and a posed sprite starts on pose 0.
        boot = { pos_x => start_x, pos_y => start_y, old_x => start_x, old_y => start_y, active => (shown ? 1 : 0) }
        boot[pose_var] = 0 if has_poses
        boot.each do |var_name, value|
          at_boot(Build.set(var_name, Value.node_for(value)))
          ensure_var(var_name)
        end
        register_animation(pose_var, rate, poses.length) if frames

        # Reserve the backing store (always — its RAM is fixed at build time). A
        # sprite that starts shown is drawn once at its start (capture what's under it
        # and blit it) so it's on screen before the loop and the buffer is primed for
        # the first erase; one that starts hidden draws nothing until `show`. (Declare
        # a sprite AFTER you've drawn its background, so it captures the real scenery.)
        record(Build.backing_buffer(buffer, width: width, height: height))

        handle = Sprite.new(self, x: pos_x, y: pos_y, old_x: old_x, old_y: old_y,
                                  active: active, buffer: buffer, width: width, height: height,
                                  image: (has_poses ? nil : name), poses: poses,
                                  facing_var: pose_var, facing_dirs: facing_dirs)
        @sprites << handle
        handle.draw_initial if shown
        handle
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

      # A `screen :tiled` sprite: the console draws it in hardware. Reserve a name for
      # it, boot its position and visibility, and declare it as a composited object
      # the framework draws each frame (see Builder#wait_vblank). The handle mirrors a
      # software Sprite's, so game code reads the same in either mode — including
      # `facing:` poses, which on hardware swap which of the sprite's uploaded pictures
      # the console draws (the tile data is managed for you).
      def hardware_sprite(name, at:, facing:, frames:, rate:, shown:)
        poses, facing_dirs, width, height = resolve_sprite_art(name, facing, frames)
        poses ||= [name] # a plain sprite is a single-pose object
        posed = facing || frames # does it choose a pose at run time (a facing or a frame)?
        start_x, start_y = at

        id = (@sprite_seq += 1)
        object_name = :"__obj#{id}"
        pos_x = :"__obj#{id}_x"
        pos_y = :"__obj#{id}_y"
        active = :"__obj#{id}_on"
        pose_var = (:"__obj#{id}_face" if posed) # holds which pose is showing

        # Boot the hidden state (console RAM isn't zero at power-on): its start
        # position, whether it begins shown, and (if posed) its starting pose.
        boot = { pos_x => start_x, pos_y => start_y, active => (shown ? 1 : 0) }
        boot[pose_var] = 0 if posed
        boot.each do |var_name, value|
          at_boot(Build.set(var_name, Value.node_for(value)))
          ensure_var(var_name)
        end
        register_animation(pose_var, rate, poses.length) if frames

        # The pose selector: a plain sprite always shows pose 0; a posed one shows
        # whichever pose its pose variable currently holds.
        pose = posed ? Build.var_ref(pose_var) : Build.int(0)
        record(Build.object(object_name, poses: poses, pose: pose,
                                         x: Build.var_ref(pos_x), y: Build.var_ref(pos_y),
                                         active: Build.var_ref(active)))
        handle = HardwareSprite.new(self, object_name: object_name, x: pos_x, y: pos_y,
                                          active: active, width: width, height: height,
                                          facing_var: pose_var, facing_dirs: facing_dirs)
        @hw_sprites << handle
        handle
      end

      # Work out a sprite's poses and size. An animation (+frames+) is a list of
      # same-size images the framework cycles, with no manual facing (empty dirs). A
      # faceted sprite (+facing+) has one image per direction, and facing_dirs maps
      # each direction to a pose index. A plain sprite is a single named image.
      # Returns [poses, facing_dirs, width, height].
      def resolve_sprite_art(name, facing, frames = nil)
        if frames
          poses, width, height = same_size_images!(name, "animation frame", frames)
          return [poses, {}, width, height]
        end
        unless facing
          width, height = @images[name] || raise(ArgumentError,
                "sprite :#{name} needs an image named :#{name} — define it first with `image :#{name}, ...`")
          return [nil, nil, width, height]
        end

        poses, width, height = same_size_images!(name, "facing image", facing.values)
        [poses, facing.keys.each_with_index.to_h, width, height]
      end

      # Resolve a list of image names to [names, width, height], insisting each is
      # defined and they all share one size (poses swap in place — a facing pose or an
      # animation frame). +kind+ names them in the error. Shared by facing: and frames:.
      def same_size_images!(name, kind, images)
        sizes = images.map do |img|
          @images[img] || raise(ArgumentError,
                "sprite :#{name} #{kind} :#{img} is not defined — define it first with `image :#{img}, ...`")
        end
        unless sizes.uniq.size == 1
          raise ArgumentError,
                "sprite :#{name} #{kind}s must all be the same size, " \
                "got #{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}"
        end
        [images, *sizes.first]
      end

      # Guard the animation options up front: facing: and frames: are two ways to drive
      # the same pose (so not both), an animation needs at least two frames to cycle,
      # and it needs a positive rate (frames-per-step). Friendly errors, not silence.
      def validate_animation!(name, facing, frames, rate)
        if facing && frames
          raise ArgumentError,
                "sprite :#{name} takes facing: OR frames:, not both — they both drive the sprite's pose"
        end
        return unless frames

        unless frames.is_a?(Array) && frames.length >= 2
          raise ArgumentError,
                "sprite :#{name} frames: needs a list of at least two images to cycle, " \
                "e.g. frames: [:step1, :step2]"
        end
        return if rate.is_a?(Integer) && rate.positive?

        raise ArgumentError,
              "sprite :#{name} frames: needs a positive rate: (how many frames each picture is shown), " \
              "got #{rate.inspect}"
      end

      # Register a flipbook so Builder#wait_vblank advances it every frame: a hidden
      # tick counter, cleared at boot, steps the pose selector to the next frame once
      # every +rate+ frames and wraps at the end. The whole timer is managed here.
      def register_animation(pose_var, rate, frame_count)
        tick = :"#{pose_var}_tick"
        at_boot(Build.set(tick, Build.int(0)))
        ensure_var(tick)
        @animations << { pose: pose_var, tick: tick, rate: rate, frames: frame_count }
      end

      # A sheet's cell size: one number means a square cell, [w, h] a rectangle.
      def normalize_tile(tile)
        case tile
        when Integer then [tile, tile]
        when Array then tile
        else raise ArgumentError, "sheet tile: must be a number (square) or [width, height], got #{tile.inspect}"
        end
      end

      # Where a named cell sits in the sheet grid: [column, row], or a single number
      # counting cells left-to-right then top-to-bottom. +img_name+ only names the
      # cell in any error.
      def sheet_cell(img_name, where, cols)
        case where
        when Array
          where
        when Integer
          [where % cols, where / cols]
        else
          raise ArgumentError,
                "sheet cell for :#{img_name} must be [column, row] or a cell number, got #{where.inspect}"
        end
      end

      # Array form of #image: validate the dimensions and pack the pixel colors.
      # +transparent+ (an internal marker color, e.g. from an imported cutout) is
      # left untouched while every other pixel is resolved — otherwise resolving it
      # would mask the marker away — and it's recorded on the bitmap so `blit`
      # skips those pixels, letting the background show through.
      def define_pixel_image(name, width:, height:, data:, transparent: nil)
        positive_dims!(name, width, height)
        expected = width * height
        unless data.length == expected
          raise ArgumentError,
                "image :#{name} is #{width}x#{height}, so it needs #{expected} pixels, but got #{data.length}"
        end

        pixels = data.map { |c| c == transparent ? transparent : Color.resolve(c) }.pack("v*")
        record(Build.bitmap(name, width: width, height: height, pixels: pixels, transparent: transparent))
        @images[name] = [width, height] # remember the shape, so a sprite can size itself from it
      end

      # ASCII-art form of #image: split the block's art into rows, infer the size
      # from its shape, map each char to a color (or transparency), and pack it.
      def define_ascii_image(name, char_map)
        rows = yield.to_s.each_line.map(&:chomp).reject(&:empty?)
        raise ArgumentError, "image :#{name} has no art" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "image :#{name} has ragged rows (#{widths.sort.join(', ')} wide) — every row must be the same length"
        end

        transparent = false
        colors = rows.flat_map do |row|
          row.each_char.map do |ch|
            spec = char_map.fetch(ch) { raise ArgumentError, "image :#{name}: no color mapped for '#{ch}'" }
            if spec == :transparent
              transparent = true
              TRANSPARENT_PIXEL
            else
              Color.resolve(spec)
            end
          end
        end

        record(Build.bitmap(name, width: widths.first, height: rows.size,
                                  pixels: colors.pack("v*"),
                                  transparent: transparent ? TRANSPARENT_PIXEL : nil))
        @images[name] = [widths.first, rows.size] # remember the shape, so a sprite can size itself from it
      end

      def positive_dims!(name, width, height)
        return if width.is_a?(Integer) && width.positive? && height.is_a?(Integer) && height.positive?

        raise ArgumentError, "image :#{name} needs positive width and height (got #{width}x#{height})"
      end
    end
  end
end
