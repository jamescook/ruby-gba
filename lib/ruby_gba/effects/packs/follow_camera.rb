# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # A camera that follows a character through a world bigger than the screen — the
      # view almost every adventure game uses. The hero stays put and the world slides
      # past underneath.
      #
      # This is a pack, so every line is written in public DSL verbs. What it stands on is
      # kernel: a `background` that scrolls, and a hardware sprite the console composites
      # over it. Following is not — it is two statements a frame and two hidden variables.
      #
      # WHAT IT ACTUALLY CHANGES, which is more than saving a line. Without it, a game
      # whose world is bigger than the screen has to keep the hero's WORLD position in
      # variables of its own, pin the sprite's picture somewhere by hand, and point the
      # camera at the difference. The hero is then a pair of numbers rather than a sprite,
      # so none of the sprite verbs apply to it: no `move` with its automatic facing, no
      # walk cycle, no poses. Written this way the hero is moved with `move` like any
      # other sprite, and what the movement drives is the camera.
      #
      # HOW. Every frame the routine looks at how far the sprite has drifted from where it
      # is meant to sit, scrolls the world by exactly that much, and puts the sprite back.
      # The drift is the movement the game just made, so the world moves instead of the
      # hero — and because the sprite is put back before it is drawn, the picture never
      # leaves its spot.
      #
      #   held(:right).then { hero.move :right }   # ordinary sprite code...
      #   # ...and the world slides left instead, because the camera follows.
      #
      # WHAT DOES NOT COMPOSE, and it is worth knowing rather than discovering: the
      # sprite's position is where it sits on the SCREEN, not where it stands in the
      # world. So `blocked_by` (whose walls are places on the map) and `overlaps?` against
      # something placed in the world do not line up with it. Moving, facing, animating
      # and turning all do.
      module FollowCamera
        HOME_X = :__camera_home_x # where the followed sprite sits on screen
        HOME_Y = :__camera_home_y
        ROUTINE = :__camera_follow

        # Point the camera at +sprite+ and keep it there, scrolling +across+ under it.
        #
        #   world = background :world, tiles: :terrain, map: MAP
        #   hero  = sprite :guy, at: [0, 0]
        #   hero.center_on_screen
        #   camera_follows hero, across: world
        #
        # Call it once, where the sprite is declared. Wherever the sprite is standing at
        # that moment is where it stays — the middle of the screen for an adventure game,
        # low down for a platformer, wherever you put it. From there the framework moves
        # the world under it every frame.
        #
        # One sprite per game leads the camera. Calling it again with a different sprite
        # is a friendly error rather than two cameras fighting over one world.
        #
        # `at:` says where in the WORLD the character starts, which is the question you
        # want answered right here and which the sprite's own position cannot answer — that
        # is where it sits on the screen, and under a follow camera those are two different
        # things. Leave it out to start at the world's top-left corner.
        #
        #   camera_follows hero, across: world, at: [120, 80]   # standing by the pond
        #
        # @param sprite [HardwareSprite] the character to follow
        # @param across [Background] the world it walks through
        # @param at [Array(Integer, Integer), nil] where the character stands in the world
        def camera_follows(sprite, across:, at: nil)
          follow_camera_arguments!(sprite, across, at)

          @follow_camera ||= begin
            home_x = var HOME_X, 0
            home_y = var HOME_Y, 0
            # Read at boot rather than written as numbers, so wherever the author left the
            # sprite is where it stays — including a `center_on_screen` just above.
            home_x.set sprite.x
            home_y.set sprite.y
            # Put the world where the character is standing in it. The window's corner sits
            # as far back from their world position as they sit into the screen.
            across.scroll_to(-sprite.x + at[0], -sprite.y + at[1]) if at

            once_a_frame(ROUTINE) do
              across.scroll_by sprite.x - home_x, sprite.y - home_y
              sprite.move_to home_x, home_y
            end

            sprite
          end
          sprite
        end

        # The guardrail this pack brings with it — the same footgun the other effects have,
        # for the same reason, so it reads the same way.
        def self.checks
          @checks ||= [NeedsGameLoop.new]
        end

        # A follow camera with no frames to happen on.
        #
        # Following is a small correction made once per frame, so it only exists over time.
        # The framework runs it at the frame boundary a `game_loop` gives it. With no game
        # loop there is no boundary: the world never scrolls, and the hero walks off the
        # edge of the screen and keeps going.
        class NeedsGameLoop
          NAME = :follow_camera_needs_game_loop

          MESSAGE =
            "This game follows a character with `camera_follows`, but it has no " \
            "`game_loop`. A camera moves the world a little on every frame, so it needs " \
            "frames to run on. With no game loop there are none: the world never moves, " \
            "and the character walks off the screen. To fix this, put the game in a " \
            "`game_loop`."

          def detect(program)
            return [] unless declared?(program)
            return [] if called?(program)

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: trigger(program) || :program)]
          end

          private

          def declared?(program)
            program.each.any? { |node| node.kind == :func && node.name == ROUTINE }
          end

          def called?(program)
            program.each.any? { |node| node.kind == :call && node.target == ROUTINE }
          end

          def trigger(program)
            program.each.find { |node| node.kind == :set && node.var == HOME_X }
          end
        end

        private

        # Cheap argument checking, inline where the mistake is written rather than in a
        # guardrail — these are wrong the moment they are typed.
        def follow_camera_arguments!(sprite, across, at)
          # THE SCREEN COMES FIRST, and the order is the point: on a bitmap screen nothing
          # about this verb applies, so saying "you need a background" would send somebody
          # off to make one that could not help them either. A bitmap screen has no world
          # to move through — its picture IS the screen, and panning past the edge shows
          # the backdrop rather than more of a map.
          unless @screen_mode == :tiled
            raise ArgumentError,
                  "camera_follows needs a `screen :tiled`. A world bigger than the screen " \
                  "is a `background` of tiles, and only a tiled screen has one. On a " \
                  "bitmap screen the picture is the screen, so use `camera` to pan it."
          end
          unless sprite.respond_to?(:move_to) && sprite.respond_to?(:x)
            raise ArgumentError,
                  "camera_follows needs a sprite to follow. You gave #{sprite.inspect}."
          end
          unless across.respond_to?(:scroll_by)
            raise ArgumentError,
                  "camera_follows needs a background to scroll, given as `across:`. " \
                  "You gave #{across.inspect}. Make one with " \
                  "`background :world, tiles: :terrain, map: MAP`."
          end
          unless at.nil? || (at.is_a?(Array) && at.length == 2 && at.all? { |n| n.is_a?(Integer) })
            raise ArgumentError,
                  "camera_follows takes `at:` as a place in the world, like `at: [120, 80]`. " \
                  "You gave #{at.inspect}."
          end
          return if @follow_camera.nil? || @follow_camera.equal?(sprite)

          raise ArgumentError,
                "this game already follows another sprite. One camera can follow one " \
                "character. To fix this, call camera_follows once."
        end
      end
    end
  end
end
