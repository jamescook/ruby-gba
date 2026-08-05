# frozen_string_literal: true

module RubyGBA
  class Builder
    # Sprite creation: the `sprite` verb, software + hardware sprites, facing /
    # frames / directional / named-clip animation, and hitboxes.
    module Sprites
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
          poses, clips, width, height, durations = import_aseprite(name, from_aseprite, transparent)
          return clip_hardware_sprite(name, at: at, poses: poses, clips: clips, durations: durations, width: width, height: height, shown: shown, hitbox: hitbox) \
            if @screen_mode == :tiled

          return clip_sprite(name, at: at, poses: poses, clips: clips, durations: durations, width: width, height: height, shown: shown, hitbox: hitbox)
        end
        if facing_from
          raise ArgumentError, "sprite :#{name} has both facing: and facing_from:. They both set the facing poses. Use only one." if facing
          raise ArgumentError, "sprite :#{name} has both facing_from: and frames:. They both set the sprite's pose. Use only one." if frames
          raise ArgumentError, "sprite :#{name} has both facing_from: and frames_from:. They both slice a sheet for the pose. Use only one." if frames_from

          facing = import_facing(name: name, path: facing_from, tile: tile, dirs: dirs, transparent: transparent)
        end
        if frames_from
          raise ArgumentError, "sprite :#{name} has both frames: and frames_from:. They both supply the frames. Use only one." if frames

          frames = import_frames(name: name, path: frames_from, tile: tile, transparent: transparent)
        end
        validate_animation!(name, facing, frames, rate, frames_from: frames_from)
        return hardware_sprite(name, at: at, facing: facing, frames: frames, rate: rate, shown: shown, hitbox: hitbox) \
          if @screen_mode == :tiled

        poses, facing_dirs, width, height, frames_per_dir = resolve_sprite_art(name, facing, frames)
        has_poses = !poses.nil?
        animated_facing = frames_per_dir > 1 # a facing: with a list of frames per direction
        box = collision_box(name: name, images: poses || [name], width: width, height: height, hitbox: hitbox)
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

      # Make a hardware sprite able to turn (see HardwareSprite#face_angle / #turn):
      # allocate its rotation-angle variable, boot it to 0 (upright), and swap the
      # object's angle operand from its default constant 0 to that variable, so the
      # backends rotate the picture each frame. Idempotent — the first turn request
      # wires it up (the operand is still the constant 0), later ones find a variable
      # already there and return. An object that never turns keeps the constant 0 and
      # pays nothing for rotation. Called by the HardwareSprite handle, so it's public.
      def make_object_rotatable(object_node, angle_var)
        return unless object_node[:angle].kind == :int # already turning (a variable angle)

        at_boot(Build.set(angle_var, Build.int(0)))
        ensure_var(angle_var)
        object_node[:angle] = Build.var_ref(angle_var)
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
        box = collision_box(name: name, images: poses, width: width, height: height, hitbox: hitbox)
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
        object_node = Build.object(object_name, poses: poses, pose: pose,
                                                x: Build.var_ref(pos_x), y: Build.var_ref(pos_y),
                                                active: scene_gate(Build.var_ref(active)))
        record(object_node)
        handle = HardwareSprite.new(self, object_name: object_name, object_node: object_node, x: pos_x, y: pos_y,
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
      def collision_box(name:, images:, width:, height:, hitbox:)
        case hitbox
        when nil then visible_bounds_union(images)
        when :full then [0, 0, width, height]
        when Integer then inset_box(name: name, width: width, height: height, by: hitbox)
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

      def inset_box(name:, width:, height:, by:)
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

      # Refuse a second pose source alongside from_aseprite: (they all set the sprite's
      # pictures, so only one makes sense).
      def reject_other_pose_sources!(name, facing:, frames:, frames_from:, facing_from:)
        other = { "facing:" => facing, "frames:" => frames,
                  "frames_from:" => frames_from, "facing_from:" => facing_from }.find { |_, value| value }
        return unless other

        raise ArgumentError,
              "sprite :#{name} has both from_aseprite: and #{other.first}. They both set the sprite's pose. Use only one."
      end

      # Turn a frame's duration (milliseconds) into a whole number of game frames (the
      # console runs at about 60 a second), at least 1 so a very fast frame still advances.
      def duration_frames(ms)
        [((ms * 60.0) / 1000).round, 1].max
      end

      # Set up the runtime state a named-clip sprite needs and boot it playing the first
      # clip. The frame timer cycles the frame within the current clip's length — a variable
      # play() rewrites to switch clips — and holds each frame for its OWN duration, read at
      # run time from a hidden list of per-frame holds indexed by the pose showing now. So a
      # frame the artist held longer plays longer. Returns the variables the sprite draws and
      # play() rewrites: [offset, length, frame].
      def setup_clip_animation(id, clips, durations)
        off = :"__clip#{id}_off"
        len = :"__clip#{id}_len"
        frame = :"__clip#{id}_frame"
        tick = :"__clip#{id}_tick"
        holds = :"__clip#{id}_holds" # a list of each pose's hold, in game frames
        first = clips.values.first
        { off => first[:off], len => first[:len], frame => 0, tick => 0 }.each do |var, value|
          at_boot(Build.set(var, Build.int(value)))
          ensure_var(var)
        end
        at_boot(Build.list_new(holds, durations.length))
        durations.each { |hold| at_boot(Build.list_push(holds, hold)) }
        # The rate is the current pose's own hold: the pose (offset + frame) looked up in the
        # holds list. `frames` (the wrap) is the clip's length variable.
        rate = Build.list_get(holds, Build.binop(:+, Build.var_ref(off), Build.var_ref(frame)))
        @animations << { pose: frame, tick: tick, rate: rate, frames: len }
        [off, len, frame]
      end

      # A software (bitmap) sprite driven by named animation clips: +poses+ is every frame,
      # +clips+ maps a name to { off:, len: }, and +durations+ is each frame's hold. Tool-
      # agnostic — it takes what an importer produced (Aseprite today; another tool would add
      # its own #import_* adapter and reuse this). Its pose is the current clip's offset plus
      # the frame within it, and play() switches clips.
      def clip_sprite(name, at:, poses:, clips:, durations:, width:, height:, shown:, hitbox:)
        box = collision_box(name: name, images: poses, width: width, height: height, hitbox: hitbox)
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
        off, len, frame = setup_clip_animation(id, clips, durations)

        record(Build.backing_buffer(buffer, width: width, height: height))
        handle = Sprite.new(self, x: pos_x, y: pos_y, old_x: old_x, old_y: old_y,
                                  active: active, buffer: buffer, hitbox: box, pixel_perfect: hitbox.nil?,
                                  image: nil, poses: poses, facing_dirs: {},
                                  clips: clips, clip_off_var: off, clip_len_var: len, frame_var: frame)
        @sprites << handle
        handle.draw_initial if shown
        handle
      end

      # A hardware (tiled) sprite driven by named animation clips — the console composites
      # it. Tool-agnostic, the same clip model as #clip_sprite; the object's pose is the
      # current clip's offset plus the frame within it.
      def clip_hardware_sprite(name, at:, poses:, clips:, durations:, width:, height:, shown:, hitbox:)
        box = collision_box(name: name, images: poses, width: width, height: height, hitbox: hitbox)
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
        off, len, frame = setup_clip_animation(id, clips, durations)

        pose = Build.binop(:+, Build.var_ref(off), Build.var_ref(frame)) # clip start + frame within it
        object_node = Build.object(object_name, poses: poses, pose: pose,
                                                x: Build.var_ref(pos_x), y: Build.var_ref(pos_y),
                                                active: scene_gate(Build.var_ref(active)))
        record(object_node)
        handle = HardwareSprite.new(self, object_name: object_name, object_node: object_node, x: pos_x, y: pos_y,
                                          active: active, hitbox: box, poses: poses, pixel_perfect: hitbox.nil?,
                                          facing_dirs: {},
                                          clips: clips, clip_off_var: off, clip_len_var: len, frame_var: frame)
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
    end
  end
end
