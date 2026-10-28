# frozen_string_literal: true

module VBlank
  module IR
    # HOW MANY FRAMES A PASS OF THE GAME LOOP TOOK, as a contract every backend keeps.
    #
    # A game loop waits for the screen, does its work, and comes round again. While the work fits
    # in the time between two frames, one pass IS one frame and nothing has to be counted. When
    # the work does not fit, a pass spans two frames or three — and anything that was counting
    # passes and calling them frames is counting the wrong thing.
    #
    # The names live here rather than in a backend because the question is not about any one
    # machine. A target that shows frames can answer it; how it knows is its own business (one
    # reads the screen's own interrupt, another simply knows it is never late).
    module Frames
      # Frames since the program started.
      COUNT = :__frames

      # What that was at the top of the last pass, and the difference between then and now — how
      # many frames the pass that just ended has to answer for. One, on a program that keeps up.
      SEEN = :__frames_seen
      STEP = :__frame_step

      # THE MOST A SINGLE PASS MAY ANSWER FOR. A pass that took half a second is a loading
      # screen, a first frame, or a hitch — and whatever reads this would then be asked to do
      # thirty frames of catching up inside one already-late pass, which is how a slow program
      # talks itself into being a stopped one.
      #
      # Capped HERE and not in each thing that reads it, which is the whole point of the cap
      # living with the number. Ten is the original Wolfenstein's own limit (MAXTICS) and it is a
      # sixth of a second — long enough that no ordinary pass reaches it.
      MOST = 10

      # WHAT A GAME LOOP PLACES AT THE FRAME BOUNDARY FOR THE DISPLAY, which the builder puts in the
      # gap after the loop's wait among the rest it does there: where each background it moves
      # sits, the top of each status bar, the map and the colours each background was handed, how
      # each turning one is turned, the tiles and sprite lists painted since, and the frame's
      # sprites — each write held to its scene's turn, or to a change, by an `if`. The builder
      # moves every such write out of the game's own lines to put it there, so a statement of the
      # loop holding one of these is one of the boundary's.
      PLACED_AT_BOUNDARY = %i[scroll_background place_bar show_map background_colors affine_background
                              copy_owed_tiles color_list_holds present_objects].freeze

      # ...and the routines that put the frame's sprites in order for it (a pool's things, a
      # `draw_in_order`), by the kind of name the builder makes for each (Messages::MadeNames).
      ORDERING_SPRITES = %i[pool_stacking draw_order].freeze

      # Is +statement+ one of the boundary's writes for the display (PLACED_AT_BOUNDARY,
      # ORDERING_SPRITES)?
      def self.placed_at_boundary?(statement)
        statement.walk.any? do |node|
          PLACED_AT_BOUNDARY.include?(node.kind) ||
            (node.kind == :call && ORDERING_SPRITES.include?(Messages::MadeNames.read(node.target)&.first))
        end
      end

      # A game loop as a console runs it: +before+, what runs once before the loop; +each_time+,
      # what the loop runs each time round; +placed+, the boundary's writes among those, which a
      # pass that put a background up does not let move that background off its corner
      # (Reference#put_up_background) — the frame it was put up for shows it from there; and
      # +variables+, the ones it keeps of its own (#loop_in_console_order).
      #
      # +pass_end+ is what ends each pass before its wait, which a pass that halts runs first too:
      # the game's last picture is placed as any pass's is.
      ConsoleLoop = Data.define(:before, :each_time, :placed, :variables, :pass_end) do
        def placed?(node) = placed.any? { |write| write.equal?(node) }
      end

      # A game loop's +statements+ in the order +console+ (a Console::Description) runs them (see
      # ConsoleLoop). On a console that sends its sprites and scroll from a copy as the wait ends
      # (Description#sprites_placed_before_wait), each pass ends by placing what is placed at the
      # boundary and then waits, so the frame after the wait shows the pass that just ended — as
      # one that writes them straight in after the wait shows it. The first wait, at power-on,
      # comes before any pass, so it has nothing to place and runs once before the loop. Every
      # backend that runs such a console, the interpreter included, takes the loop in this order.
      #
      # THE FRAME SHOWS THE SCENE THE PASS RAN. What a scene owns is placed while its scene is up,
      # which the builder writes as a test of the game's scene number (Builder#scene_up). A scene
      # that hands over sets that number as it runs, and the next scene comes up in the next pass;
      # so at the end of the pass the number already names the next scene, while the frame still
      # shows this one. So each scene dispatch of the loop notes the number it read, and the
      # boundary's writes are placed with the number put back to that for as long as they run.
      def self.loop_in_console_order(statements, console)
        as_written = ConsoleLoop.new(before: [], each_time: statements, placed: [], variables: [], pass_end: [])
        return as_written unless console.sprites_placed_before_wait && statements.first&.kind == :wait_vblank

        wait = statements.first
        placed, body = statements.drop(1).partition { |node| placed_at_boundary?(node) }
        return as_written if placed.empty?

        scene_numbers = body.select { |node| scene_dispatch?(node) }.map(&:var).uniq
        read = ->(number) { :"__scene_read_#{number}" }
        held = ->(number) { :"__scene_held_#{number}" }
        noted = body.flat_map { |node| scene_dispatch?(node) ? [Build.set(read.call(node.var), Build.var_ref(node.var)), node] : [node] }
        put_back = scene_numbers.flat_map do |number|
          [Build.set(held.call(number), Build.var_ref(number)), Build.set(number, Build.var_ref(read.call(number)))]
        end
        restored = scene_numbers.map { |number| Build.set(number, Build.var_ref(held.call(number))) }
        pass_end = [*put_back, *placed, *restored]
        ConsoleLoop.new(before: [wait], each_time: [*noted, *pass_end, wait], placed: placed, pass_end: pass_end,
                        variables: scene_numbers.flat_map { |number| [read.call(number), held.call(number)] })
      end

      # A `case` that hands the screen to a scene: one whose clauses call scenes. A game's own
      # dispatch on a number of its own is left as it is.
      def self.scene_dispatch?(node) = node.kind == :case && node.clauses.any? { |_, target| Modes.scene_func?(target) }

      # THE STATEMENTS A BEAT MEANS — `every` and `after` (Reference#exec_every, #exec_after) —
      # said as the plain ones every lowering already makes, so none of them writes the rule
      # again. The beat's counter moves on by the frames the pass answers for, and at least one:
      # before the first frame has ended nothing has been counted yet, and that pass is a frame.
      #
      # A repeating beat takes its period off rather than starting again from nought, so one
      # that overshoots keeps the remainder. A one-shot fires when its count is REACHED rather
      # than landed on, because a pass worth two frames can step over the frame it waited for,
      # and stops counting once it has fired, so it never fires twice.
      def self.beat_statements(node)
        frames = Build.clamped(Build.var_ref(STEP), Build.int(1), Build.int(Int32::MAX))
        counter = Build.var_ref(node.counter)
        case node.kind
        when :every
          reached = Build.binop(:>=, counter, Build.int(node.period))
          [Build.add(node.counter, frames), Build.if_(reached, Build.sub(node.counter, node.period), *node.children)]
        when :after
          fires = Build.if_(Build.binop(:>=, counter, Build.int(node.frames)), *node.children)
          [Build.if_(Build.binop(:<, counter, Build.int(node.frames)), Build.add(node.counter, frames), fires)]
        else
          raise ArgumentError, "#{node.kind.inspect} is not a beat"
        end
      end
    end
  end
end
