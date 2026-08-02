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
          bmp = Image.load(resolve_asset_path(opts[:from]), width: opts[:width], height: opts[:height],
                                                            transparent: opts.fetch(:transparent, false))
          define_pixel_image(name, width: bmp.width, height: bmp.height, data: bmp.data,
                                   transparent: bmp.transparent)
        else
          define_pixel_image(name, width: opts[:width], height: opts[:height], data: opts[:data],
                                   transparent: opts[:transparent])
        end
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
      # Or skip drawing the frames by hand and IMPORT them from a sprite sheet — one
      # image file holding the frames in a row (or grid). +frames_from:+ names the
      # file and +tile:+ the size of each frame; every cell becomes a frame, in order,
      # so there's nothing to name or number:
      #
      #   run = sprite :hero, at: [x, y], frames_from: "hero.png", tile: 16, rate: 8, transparent: true
      #
      # +transparent: true+ honors the sheet's cut-out background so only the figure
      # draws, not a box around it. The file is found next to your script.
      #
      # +facing:+, +frames:+, and +frames_from:+ all supply the sprite's pictures, so
      # a sprite takes exactly one of them.
      #
      # @param name [Symbol] a defined image (its size becomes the sprite's size), or
      #   just the sprite's identity when the poses come from +facing:+/+frames:+/+frames_from:+
      # @param at [Array(Integer, Integer)] the sprite's starting [x, y]
      # @param facing [Hash{Symbol=>Symbol}, nil] direction => image, for a sprite that turns
      # @param frames [Array<Symbol>, nil] same-size images to cycle as an animation
      # @param frames_from [String, nil] a sprite-sheet image file to slice into frames
      # @param tile [Integer, Array(Integer, Integer), nil] frame size for +frames_from:+
      # @param transparent [Boolean] honor the sheet's transparency (for +frames_from:+)
      # @param rate [Integer, nil] frames-per-step for +frames:+/+frames_from:+ (required with them)
      # @param shown [Boolean] draw it now (true, default), or start hidden until `show`
      # @return [Sprite, HardwareSprite] a handle: x / y / move / move_to (and, in bitmap mode, face / hide / show)
      def sprite(name, at:, facing: nil, frames: nil, frames_from: nil, facing_from: nil,
                 from_aseprite: nil, dirs: nil, tile: nil, transparent: false, rate: nil, shown: true, hitbox: nil)
        if from_aseprite
          reject_other_pose_sources!(name, facing: facing, frames: frames, frames_from: frames_from, facing_from: facing_from)
          poses, clips, width, height = import_aseprite(name, from_aseprite, transparent)
          return clip_hardware_sprite(name, at: at, poses: poses, clips: clips, width: width, height: height, shown: shown, hitbox: hitbox) \
            if @screen_mode == :tiled

          return clip_sprite(name, at: at, poses: poses, clips: clips, width: width, height: height, shown: shown, hitbox: hitbox)
        end
        if facing_from
          raise ArgumentError, "sprite :#{name} has both facing: and facing_from:. They both set the facing poses. Use only one." if facing
          raise ArgumentError, "sprite :#{name} has both facing_from: and frames:. They both set the sprite's pose. Use only one." if frames
          raise ArgumentError, "sprite :#{name} has both facing_from: and frames_from:. They both slice a sheet for the pose. Use only one." if frames_from

          facing = import_facing(name, facing_from, tile, dirs, transparent)
        end
        if frames_from
          raise ArgumentError, "sprite :#{name} has both frames: and frames_from:. They both supply the frames. Use only one." if frames

          frames = import_frames(name, frames_from, tile, transparent)
        end
        validate_animation!(name, facing, frames, rate, frames_from: frames_from)
        return hardware_sprite(name, at: at, facing: facing, frames: frames, rate: rate, shown: shown, hitbox: hitbox) \
          if @screen_mode == :tiled

        poses, facing_dirs, width, height, frames_per_dir = resolve_sprite_art(name, facing, frames)
        has_poses = !poses.nil?
        animated_facing = frames_per_dir > 1 # a facing: with a list of frames per direction
        box = collision_box(name, poses || [name], width, height, hitbox)
        start_x, start_y = at

        id = (@sprite_seq += 1)
        pos_x = :"__spr#{id}_x"
        pos_y = :"__spr#{id}_y"
        old_x = :"__spr#{id}_ox"
        old_y = :"__spr#{id}_oy"
        active = :"__spr#{id}_on"
        buffer = :"__spr#{id}_under"
        pose_var = (:"__spr#{id}_face" if has_poses) # the pose selector (a facing or a frame)
        frame_var = (:"__spr#{id}_frame" if animated_facing) # animation frame, composed with the facing

        # Hidden state, set at boot (console RAM isn't zero at power-on): the current
        # and last-drawn positions both start at `at`, the on/off flag records
        # whether the sprite starts visible, and a posed sprite starts on pose 0.
        boot = { pos_x => start_x, pos_y => start_y, old_x => start_x, old_y => start_y, active => (shown ? 1 : 0) }
        boot[pose_var] = 0 if has_poses
        boot[frame_var] = 0 if animated_facing
        boot.each do |var_name, value|
          at_boot(Build.set(var_name, Value.node_for(value)))
          ensure_var(var_name)
        end
        # A directional animation cycles the FRAME (its direction is chosen by `face`);
        # a plain frames: animation cycles the single pose selector.
        if animated_facing
          register_animation(frame_var, rate, frames_per_dir)
        elsif frames
          register_animation(pose_var, rate, poses.length)
        end

        # Reserve the backing store (always — its RAM is fixed at build time). A
        # sprite that starts shown is drawn once at its start (capture what's under it
        # and blit it) so it's on screen before the loop and the buffer is primed for
        # the first erase; one that starts hidden draws nothing until `show`. (Declare
        # a sprite AFTER you've drawn its background, so it captures the real scenery.)
        record(Build.backing_buffer(buffer, width: width, height: height))

        handle = Sprite.new(self, x: pos_x, y: pos_y, old_x: old_x, old_y: old_y,
                                  active: active, buffer: buffer, hitbox: box, pixel_perfect: hitbox.nil?,
                                  image: (has_poses ? nil : name), poses: poses,
                                  facing_var: pose_var, facing_dirs: facing_dirs,
                                  frame_var: frame_var, frames_per_dir: frames_per_dir)
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
      def hardware_sprite(name, at:, facing:, frames:, rate:, shown:, hitbox:)
        poses, facing_dirs, width, height, frames_per_dir = resolve_sprite_art(name, facing, frames)
        poses ||= [name] # a plain sprite is a single-pose object
        animated_facing = frames_per_dir > 1 # a facing: with a list of frames per direction
        box = collision_box(name, poses, width, height, hitbox)
        posed = facing || frames # does it choose a pose at run time (a facing or a frame)?
        start_x, start_y = at

        id = (@sprite_seq += 1)
        object_name = :"__obj#{id}"
        pos_x = :"__obj#{id}_x"
        pos_y = :"__obj#{id}_y"
        active = :"__obj#{id}_on"
        pose_var = (:"__obj#{id}_face" if posed) # holds which pose is showing
        frame_var = (:"__obj#{id}_frame" if animated_facing) # animation frame, composed with the facing

        # Boot the hidden state (console RAM isn't zero at power-on): its start
        # position, whether it begins shown, and (if posed) its starting pose.
        boot = { pos_x => start_x, pos_y => start_y, active => (shown ? 1 : 0) }
        boot[pose_var] = 0 if posed
        boot[frame_var] = 0 if animated_facing
        boot.each do |var_name, value|
          at_boot(Build.set(var_name, Value.node_for(value)))
          ensure_var(var_name)
        end
        # A directional animation cycles the FRAME (its direction is chosen by `face`);
        # a plain frames: animation cycles the single pose selector.
        if animated_facing
          register_animation(frame_var, rate, frames_per_dir)
        elsif frames
          register_animation(pose_var, rate, poses.length)
        end

        # The pose selector. A plain sprite always shows pose 0. A facing or frames
        # sprite shows the pose its selector holds. A directional animation composes
        # both: pose = direction * frames_per_direction + frame.
        pose = if animated_facing
                 Build.binop(:+, Build.binop(:*, Build.var_ref(pose_var), Build.int(frames_per_dir)),
                             Build.var_ref(frame_var))
               elsif posed
                 Build.var_ref(pose_var)
               else
                 Build.int(0)
               end
        record(Build.object(object_name, poses: poses, pose: pose,
                                         x: Build.var_ref(pos_x), y: Build.var_ref(pos_y),
                                         active: scene_gate(Build.var_ref(active))))
        handle = HardwareSprite.new(self, object_name: object_name, x: pos_x, y: pos_y,
                                          active: active, hitbox: box, poses: poses, pixel_perfect: hitbox.nil?,
                                          facing_var: pose_var, facing_dirs: facing_dirs,
                                          frame_var: frame_var, frames_per_dir: frames_per_dir)
        @hw_sprites << handle
        handle
      end

      # Work out a sprite's collision box — the rectangle `overlaps?` and `blocked_by`
      # test — as [x, y, w, h] relative to the sprite's top-left. By default it's the
      # box around the sprite's visible pixels (union of every pose, so it stays put as
      # the sprite animates), which trims the wasted transparent margin so a hit isn't
      # a pixel or two of empty space early. It's still a rectangle, though — it doesn't
      # follow a round or concave outline. `hitbox:` overrides it: `:full` for the whole
      # image (the old behaviour), an Integer to shrink the whole image by that many
      # pixels on every side, or an explicit `[x, y, w, h]`.
      def collision_box(name, images, width, height, hitbox)
        case hitbox
        when nil then visible_bounds_union(images)
        when :full then [0, 0, width, height]
        when Integer then inset_box(name, width, height, hitbox)
        when Array then explicit_hitbox(name, hitbox)
        else
          raise ArgumentError,
                "sprite :#{name} hitbox: must be :full, a number of pixels to shrink each side, or [x, y, w, h]. " \
                "Got #{hitbox.inspect}."
        end
      end

      # The smallest box covering the visible pixels of every one of +images+ (a plain
      # sprite has one, a posed/animated one has several) — so the collision box holds
      # still while the picture changes.
      def visible_bounds_union(images)
        boxes = images.map { |img| @image_bounds[img] || [0, 0, *@images[img]] }
        left = boxes.map { |x, _, _, _| x }.min
        top = boxes.map { |_, y, _, _| y }.min
        right = boxes.map { |x, _, w, _| x + w }.max
        bottom = boxes.map { |_, y, _, h| y + h }.max
        [left, top, right - left, bottom - top]
      end

      def inset_box(name, width, height, by)
        if by.negative? || (2 * by) >= width || (2 * by) >= height
          raise ArgumentError,
                "sprite :#{name} hitbox: #{by} is too large. It shrinks a #{width}x#{height} sprite to nothing. " \
                "Use a smaller inset, under #{[width, height].min / 2}."
        end
        [by, by, width - (2 * by), height - (2 * by)]
      end

      def explicit_hitbox(name, box)
        ok = box.length == 4 && box.all? { |n| n.is_a?(Integer) } &&
             box[0] >= 0 && box[1] >= 0 && box[2].positive? && box[3].positive?
        return box if ok

        raise ArgumentError,
              "sprite :#{name} hitbox: must be [x, y, w, h]. x and y must be 0 or more. w and h must be more than 0. Got #{box.inspect}."
      end

      # Work out a sprite's poses and size. An animation (+frames+) is a list of
      # same-size images the framework cycles, with no manual facing (empty dirs). A
      # faceted sprite (+facing+) has one image per direction, and facing_dirs maps
      # each direction to its index. A directional animation gives each direction a LIST
      # of frames (facing: { left: [:l1, :l2], ... }): the frames flatten in direction
      # order, so pose = direction * frames_per_direction + frame. A plain sprite is a
      # single named image. Returns [poses, facing_dirs, width, height, frames_per_dir].
      def resolve_sprite_art(name, facing, frames = nil)
        if frames
          poses, width, height = same_size_images!(name, "animation frame", frames)
          return [poses, {}, width, height, 1]
        end
        unless facing
          width, height = @images[name] || raise(ArgumentError,
                "sprite :#{name} needs an image named :#{name}. Define the image first with `image :#{name}, ...`.")
          return [nil, nil, width, height, 1]
        end
        return resolve_directional_frames(name, facing) if facing.values.any? { |v| v.is_a?(Array) }

        poses, width, height = same_size_images!(name, "facing image", facing.values)
        [poses, facing.keys.each_with_index.to_h, width, height, 1]
      end

      # A directional animation: each direction is a list of the same number of frames.
      # The frames flatten in direction order (all of :left, then all of :right, ...), so
      # a pose index of direction * frames_per_direction + frame lands on the right
      # picture. facing_dirs maps each direction to its 0-based row.
      def resolve_directional_frames(name, facing)
        unless facing.values.all? { |v| v.is_a?(Array) }
          raise ArgumentError,
                "sprite :#{name} facing: gives some directions a list of frames and some a single image. " \
                "Give every direction the same shape: a list of frames each, or a single image each."
        end
        per_dir = facing.values.map(&:length).uniq
        unless per_dir.size == 1
          raise ArgumentError,
                "sprite :#{name} facing: needs the same number of frames in every direction. " \
                "Got #{facing.transform_values(&:length).inspect}."
        end
        if per_dir.first < 2
          raise ArgumentError,
                "sprite :#{name} facing: has one frame per direction, so it is not an animation. " \
                "For a still pose per direction, give a single image: facing: { left: :img_l, right: :img_r }."
        end

        poses, width, height = same_size_images!(name, "facing frame", facing.values.flatten)
        [poses, facing.keys.each_with_index.to_h, width, height, per_dir.first]
      end

      # Resolve a list of image names to [names, width, height], insisting each is
      # defined and they all share one size (poses swap in place — a facing pose or an
      # animation frame). +kind+ names them in the error. Shared by facing: and frames:.
      def same_size_images!(name, kind, images)
        sizes = images.map do |img|
          @images[img] || raise(ArgumentError,
                "sprite :#{name} #{kind} :#{img} is not defined. Define the image first with `image :#{img}, ...`.")
        end
        unless sizes.uniq.size == 1
          raise ArgumentError,
                "sprite :#{name} #{kind}s must all be the same size. " \
                "Got #{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}."
        end
        [images, *sizes.first]
      end

      # Guard the animation options up front: a sprite's pose comes from exactly one
      # of facing:/frames:/frames_from: (so not two at once), an animation needs at
      # least two frames to cycle, and it needs a positive rate (frames-per-step).
      # Friendly errors, not silence. By here frames_from: has already become frames.
      def validate_animation!(name, facing, frames, rate, frames_from: nil)
        if facing && frames
          drove = frames_from ? "frames_from:" : "frames:"
          raise ArgumentError,
                "sprite :#{name} has both facing: and #{drove}. They both set the sprite's pose. Use only one."
        end

        # A directional animation (facing: with a list of frames per direction) cycles
        # its frames, so it needs a rate the same way a plain frames: animation does.
        if facing && facing.values.any? { |v| v.is_a?(Array) && v.length >= 2 }
          return if rate.is_a?(Integer) && rate.positive?

          raise ArgumentError,
                "sprite :#{name} needs a positive rate: (how many game frames each picture is shown). Got #{rate.inspect}."
        end
        return unless frames

        source = frames_from ? "frames_from: needs a sheet of at least two frames" : "frames: needs a list of at least two images to cycle, for example frames: [:step1, :step2]"
        unless frames.is_a?(Array) && frames.length >= 2
          raise ArgumentError, "sprite :#{name} #{source}"
        end
        return if rate.is_a?(Integer) && rate.positive?

        raise ArgumentError,
              "sprite :#{name} needs a positive rate: (how many frames each picture is shown). Got #{rate.inspect}."
      end

      # Import a sprite sheet into animation frames: slice the file into cells of the
      # given size and define each as an image, in row-major order. Returns the list
      # of frame image names, ready for the flipbook path — so `frames_from:` needs no
      # naming or numbering, just "cut it up and cycle the pieces."
      def import_frames(name, path, tile, transparent)
        tile_w, tile_h = sheet_tile_size("sprite :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        (0...(sheet.cols * sheet.rows)).map do |i|
          bmp = sheet.cell(i % sheet.cols, i / sheet.cols)
          frame = :"__frame_#{name}_#{i}"
          define_pixel_image(frame, width: bmp.width, height: bmp.height, data: bmp.data,
                                    transparent: bmp.transparent)
          frame
        end
      end

      # Import a directional sprite sheet into facing: poses. The sheet is a grid: each
      # ROW is a direction (in the order dirs: gives, top to bottom), and the COLUMNS of
      # that row are its frames. So a one-column sheet gives one still pose per direction
      # (a plain facing: sprite), and a several-column sheet gives a per-direction
      # animation (a walk cycle each way it faces). Returns the facing: hash the normal
      # sprite path then handles — a single image per direction, or a list of frames.
      def import_facing(name, path, tile, dirs, transparent)
        unless dirs.is_a?(Array) && dirs.any? && dirs.all? { |d| d.is_a?(Symbol) }
          raise ArgumentError,
                "sprite :#{name} facing_from: needs dirs: — the direction of each row of the sheet, " \
                "top to bottom, like dirs: [:down, :left, :right, :up]. Got #{dirs.inspect}."
        end

        tile_w, tile_h = sheet_tile_size("sprite :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        unless sheet.rows == dirs.length
          raise ArgumentError,
                "sprite :#{name} facing_from: has #{sheet.rows} rows, but dirs: names #{dirs.length}. " \
                "Give one direction for each row of the sheet."
        end

        dirs.each_with_index.to_h do |dir, row|
          frames = (0...sheet.cols).map do |col|
            bmp = sheet.cell(col, row)
            img = :"__face_#{name}_#{dir}_#{col}"
            define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data, transparent: bmp.transparent)
            img
          end
          # One column: a still pose per direction. Several: this direction's frame list.
          [dir, sheet.cols == 1 ? frames.first : frames]
        end
      end

      # Refuse a second pose source alongside from_aseprite: (they all set the sprite's
      # pictures, so only one makes sense).
      def reject_other_pose_sources!(name, facing:, frames:, frames_from:, facing_from:)
        other = { "facing:" => facing, "frames:" => frames,
                  "frames_from:" => frames_from, "facing_from:" => facing_from }.find { |_, value| value }
        return unless other

        raise ArgumentError,
              "sprite :#{name} has both from_aseprite: and #{other.first}. They both set the sprite's pose. Use only one."
      end

      # Import an Aseprite sprite-sheet export (a PNG plus its JSON) into sprite frames and
      # named animations. The JSON gives each frame's exact rectangle and each named
      # animation (frameTag); this slices those rectangles out of the PNG (found from the
      # JSON's own meta.image, beside the JSON) and defines one image per frame. Returns
      # [frame image names, clips, width, height], where clips maps each animation name to
      # { off:, len:, rate: } — its first frame, its length, and a frame rate from the
      # frames' durations. A sheet with no tags becomes one clip named :all.
      def import_aseprite(name, file_path, transparent)
        frames, tags = load_aseprite(name, resolve_asset_path(file_path), transparent)
        poses = frames.each_with_index.map do |frame, i|
          img = :"__ase_#{name}_#{i}"
          define_pixel_image(img, width: frame.width, height: frame.height, data: frame.data, transparent: frame.transparent)
          img
        end
        _poses, width, height = same_size_images!(name, "Aseprite frame", poses)

        tags = [Aseprite::Tag.new(:all, 0, frames.length - 1)] if tags.empty?
        clips = tags.to_h do |tag|
          [tag.name, { off: tag.from, len: (tag.to - tag.from) + 1, rate: clip_rate(frames[tag.from..tag.to]) }]
        end
        [poses, clips, width, height]
      end

      # Load an Aseprite sprite as [frames, tags], where each frame carries its pixels and
      # its duration. Reads either the native binary (.aseprite / .ase) straight — no export
      # step — or a JSON + PNG export (the JSON names its PNG, found beside it).
      def load_aseprite(name, path, transparent)
        if path.downcase.end_with?(".aseprite", ".ase")
          sprite = Aseprite.load_binary(File.binread(path))
          return [sprite.frames, sprite.tags]
        end

        doc = Aseprite.parse(File.read(path))
        unless doc.image
          raise ArgumentError,
                "sprite :#{name} from_aseprite: #{path.inspect} does not name its image. " \
                "Re-export from Aseprite with the JSON data option, which records the PNG name."
        end
        sheet = Image.load_sheet(File.expand_path(doc.image, File.dirname(path)), transparent: transparent)
        frames = doc.frames.map do |f|
          bmp = sheet.region(f.x, f.y, f.w, f.h)
          Aseprite::FrameImage.new(bmp.width, bmp.height, bmp.data, bmp.transparent, f.duration)
        end
        [frames, doc.tags]
      end

      # A named clip's frame rate: turn the frames' duration (milliseconds) into a whole
      # number of game frames (the console runs at about 60 a second). One uniform rate
      # per clip — the common case, where a cycle's frames share a duration. At least 1,
      # so a very fast clip still advances.
      def clip_rate(frames)
        ms = frames.map(&:duration).max
        [((ms * 60.0) / 1000).round, 1].max
      end

      # Set up the runtime state a named-clip sprite needs and boot it playing the first
      # clip. The frame timer cycles the frame within the CURRENT clip's length, at the
      # current clip's rate — both held in variables, so `play` switches clips by just
      # rewriting them. Returns the variable names the sprite draws and play() rewrite:
      # [offset, length, rate, frame].
      def setup_clip_animation(id, clips)
        off = :"__clip#{id}_off"
        len = :"__clip#{id}_len"
        rate = :"__clip#{id}_rate"
        frame = :"__clip#{id}_frame"
        tick = :"__clip#{id}_tick"
        first = clips.values.first
        { off => first[:off], len => first[:len], rate => first[:rate], frame => 0, tick => 0 }.each do |var, value|
          at_boot(Build.set(var, Build.int(value)))
          ensure_var(var)
        end
        # rate and frames are variable names, so the timer reads the current clip's values.
        @animations << { pose: frame, tick: tick, rate: rate, frames: len }
        [off, len, rate, frame]
      end

      # A software (bitmap) sprite driven by named animation clips: +poses+ is every frame
      # and +clips+ maps a name to { off:, len:, rate: }. Tool-agnostic — it takes the
      # clips an importer produced (Aseprite today; another tool would add its own
      # #import_* adapter and reuse this). Its pose is the current clip's offset plus the
      # frame within it, and play() switches clips.
      def clip_sprite(name, at:, poses:, clips:, width:, height:, shown:, hitbox:)
        box = collision_box(name, poses, width, height, hitbox)
        start_x, start_y = at
        id = (@sprite_seq += 1)
        pos_x = :"__spr#{id}_x"
        pos_y = :"__spr#{id}_y"
        old_x = :"__spr#{id}_ox"
        old_y = :"__spr#{id}_oy"
        active = :"__spr#{id}_on"
        buffer = :"__spr#{id}_under"

        { pos_x => start_x, pos_y => start_y, old_x => start_x, old_y => start_y, active => (shown ? 1 : 0) }.each do |var, value|
          at_boot(Build.set(var, Value.node_for(value)))
          ensure_var(var)
        end
        off, len, rate, frame = setup_clip_animation(id, clips)

        record(Build.backing_buffer(buffer, width: width, height: height))
        handle = Sprite.new(self, x: pos_x, y: pos_y, old_x: old_x, old_y: old_y,
                                  active: active, buffer: buffer, hitbox: box, pixel_perfect: hitbox.nil?,
                                  image: nil, poses: poses, facing_dirs: {},
                                  clips: clips, clip_off_var: off, clip_len_var: len, clip_rate_var: rate, frame_var: frame)
        @sprites << handle
        handle.draw_initial if shown
        handle
      end

      # A hardware (tiled) sprite driven by named animation clips — the console composites
      # it. Tool-agnostic, the same clip model as #clip_sprite; the object's pose is the
      # current clip's offset plus the frame within it.
      def clip_hardware_sprite(name, at:, poses:, clips:, width:, height:, shown:, hitbox:)
        box = collision_box(name, poses, width, height, hitbox)
        start_x, start_y = at
        id = (@sprite_seq += 1)
        object_name = :"__obj#{id}"
        pos_x = :"__obj#{id}_x"
        pos_y = :"__obj#{id}_y"
        active = :"__obj#{id}_on"

        { pos_x => start_x, pos_y => start_y, active => (shown ? 1 : 0) }.each do |var, value|
          at_boot(Build.set(var, Value.node_for(value)))
          ensure_var(var)
        end
        off, len, rate, frame = setup_clip_animation(id, clips)

        pose = Build.binop(:+, Build.var_ref(off), Build.var_ref(frame)) # clip start + frame within it
        record(Build.object(object_name, poses: poses, pose: pose,
                                         x: Build.var_ref(pos_x), y: Build.var_ref(pos_y),
                                         active: scene_gate(Build.var_ref(active))))
        handle = HardwareSprite.new(self, object_name: object_name, x: pos_x, y: pos_y,
                                          active: active, hitbox: box, poses: poses, pixel_perfect: hitbox.nil?,
                                          facing_dirs: {},
                                          clips: clips, clip_off_var: off, clip_len_var: len, clip_rate_var: rate, frame_var: frame)
        @hw_sprites << handle
        handle
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
                "image :#{name} is #{width}x#{height}, so it needs #{expected} pixels. Got #{data.length}."
        end

        pixels = data.map { |c| c == transparent ? transparent : Color.resolve(c) }.pack("v*")
        record(Build.bitmap(name, width: width, height: height, pixels: pixels, transparent: transparent))
        @images[name] = [width, height] # remember the shape, so a sprite can size itself from it
        record_visible_bounds(name, width, height, data, transparent)
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

        record(Build.bitmap(name, width: widths.first, height: rows.size,
                                  pixels: colors.pack("v*"),
                                  transparent: transparent ? TRANSPARENT_PIXEL : nil))
        @images[name] = [widths.first, rows.size] # remember the shape, so a sprite can size itself from it
        record_visible_bounds(name, widths.first, rows.size, colors, transparent ? TRANSPARENT_PIXEL : nil)
      end

      # Remember the box around an image's visible (non-transparent) pixels, so a
      # sprite made from it collides on the art itself, not the empty margin around it.
      # +cells+ is the image's pixels row-major and +transparent+ the value that marks a
      # see-through one (nil if the image is fully opaque — then the box is the whole
      # image). A blank image (nothing but transparent) also falls back to the whole
      # image, so its collision box is never empty.
      def record_visible_bounds(name, width, height, cells, transparent)
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
        return if width.is_a?(Integer) && width.positive? && height.is_a?(Integer) && height.positive?

        raise ArgumentError, "image :#{name} needs a width and height above 0. Got #{width}x#{height}."
      end
    end
  end
end
