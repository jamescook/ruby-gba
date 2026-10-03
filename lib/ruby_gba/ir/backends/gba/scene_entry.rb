# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT HAS TO HAPPEN ONCE AS A SCENE TAKES OVER, AND NOT ON EVERY FRAME IT RUNS.
        #
        # A scene's own routine is reached on every frame it is the active state, so anything
        # in it that sets the console UP rather than moving what is already there has to be
        # guarded: sending its scenery's maps and pictures, sending its sprites' pictures.
        # Both are a copy, and both throw away whatever the game has done since if repeated.
        #
        # The guard is a note in memory saying whose scenery, or whose sprite pictures, are
        # up: a scene number counting from 1, so that 0 means nobody's. A scene taking over
        # finds a number that is not its own, does the work and writes its own; a scene
        # already running finds its own and skips it — one compare a frame. This is the one
        # place that numbers the scenes, keeps those notes and clears them, because the way
        # this has gone wrong before is one part of the console build forgetting to clear a
        # note another part kept: after a scene with nothing of its own, and after a change to
        # a screen of another kind.
        class SceneEntry
          # The notes, one per kind of thing a scene puts up as it takes over.
          MARKERS = { scenery: :_scene_scenery, art: :_scene_art }.freeze

          def initialize(emitter:, primitives:)
            @emitter = emitter
            @primitives = primitives
            @numbers = {}
            @layout = nil
          end

          attr_writer :layout

          # Run the block's code only on the frame +scene+ takes over: when the +marker+ note
          # names some other scene, or nobody's.
          def emit_once_on_arrival(marker, scene)
            number = (@numbers[scene] ||= @numbers.size + 1)
            emit_unless_holds(MARKERS.fetch(marker), number) do
              yield
              @primitives.store_word_immediate(number, @primitives.var_addr(MARKERS.fetch(marker)))
            end
          end

          # Say nobody's +marker+ things are up — for a scene with none of its own, which still
          # takes the last scene's down (see IR::SceneHandover::Arrival).
          def emit_clear_marker(marker)
            @primitives.store_word_immediate(0, @primitives.var_addr(MARKERS.fetch(marker)))
          end

          # Say nothing is up at all. At power-on, since the console makes no promise about
          # its memory and a stale number would make the first scene skip putting its things
          # up; and wherever the display is set up again for a screen of another kind, which
          # sends its pictures afresh. Only the notes some scene uses are written, so a game
          # with no scenes of its own emits nothing here.
          def emit_clear_used_markers
            emit_clear_marker(:scenery) if scenery_by_scene?
            emit_clear_marker(:art) if @layout.scene_art.any?
          end

          # Run the block's code unless +var+ holds +value+. The cost when it does is the
          # compare and the branch.
          def emit_unless_holds(var, value)
            @primitives.load_var(ACC, var)
            @emitter.emit(ASM.cmp_imm(ACC, value))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            yield
            @emitter.place_label(skip)
          end

          private

          def scenery_by_scene? = @layout.picture.scenery.any? { |bg| @layout.handover.on_arrival?(bg) }
        end
      end
    end
  end
end
