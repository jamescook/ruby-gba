# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT GOES IN THE CONSOLE'S QUICK MEMORY, worked out from plain numbers: each routine
        # or collection that wants a place there, how big it is, which scene runs it, and whether
        # the author insisted on it. Nothing here lowers anything or reads the program;
        # {Placement} measures them and hands them over, and emits what comes back. A collection
        # is weighed like a routine with no calls that only the whole game's room can hold.
        #
        # THE RULE. What the author insisted on (`fast: true` on a routine, a scene or a save
        # record) goes in first, in the room of the scene that runs it. Then whatever the build
        # would pick for itself, best first, in what is left. An insisted routine is never turned
        # away for a routine the build picked, so whether a build fails depends only on what the
        # author insisted on — never on what the measuring run found.
        #
        # TWO WAYS TO HOLD THEM. One set of routines for the whole game, copied in at power-on; or,
        # for a game whose scenes are picked by one dispatch in the game loop, a set for each scene
        # as well, copied in as that scene takes over (see {SceneQuickMemory}). A scene's set costs
        # a word in every scene saying where each of its routines is, so it is used only when one
        # set for the whole game cannot hold what the author insisted on, or leaves something out.
        module QuickMemoryPlan
          # One routine, or one collection, that wants a place.
          #
          # +bytes+ is what it is charged, as though every call it makes crossed between the two
          # memories. +calls+ names the routine each such call goes to, one entry a call, and
          # +call_charge+ is what one of them was charged: a call to a routine kept in the same
          # place is a plain jump, and those bytes come back.
          #
          # +scene+ is the scene routine whose set may hold it — the one scene that runs it — or
          # nil for a routine that can only be kept for the whole game.
          #
          # +insisted+ is what the author wrote to insist on it ("`save_data :file, fast: true`"),
          # or nil for a routine the build is free to leave out.
          #
          # +every_frame+ marks what every frame runs or reads — the game loop, the routine the
          # console interrupts into, the routines placed with the game loop, a collection a frame
          # touches. A set per scene is not used where it would leave one of those out that one
          # set for the whole game kept.
          #
          # +scene_work+ is what a frame of each scene was measured to spend in it, by scene
          # routine — empty for a routine measured in no scene's counts, nil for one never
          # measured at all.
          Claim = Data.define(:name, :bytes, :scene, :insisted, :calls, :call_charge, :every_frame, :scene_work) do
            def initialize(scene: nil, insisted: nil, calls: [], call_charge: 0, every_frame: false, scene_work: nil,
                           **rest) = super
          end

          # The game's scene dispatch: the scene routines it names, in its order, and how many
          # clauses it has.
          Dispatch = Data.define(:scenes, :clauses)

          # A routine the build wanted and could not fit: what it needed, the room that was left,
          # and the scene routine whose room that was (nil where the game keeps one set).
          Missed = Data.define(:name, :bytes, :room, :scene)

          # What the planning settled: the routines kept for the whole game, and each scene's set by
          # its scene routine, in the order they are placed. +sets+ is empty for a game that keeps
          # one set. +charged+ is what each routine came to — a kept one less its calls to its
          # neighbours, and the game loop with the swap at its dispatch where there are sets — and
          # +missed+ the routines the build wanted and could not fit.
          Plan = Data.define(:resident, :sets, :charged, :missed) do
            def kept?(name) = resident.include?(name) || sets.any? { |_, names| names.include?(name) }
          end

          # Where a routine did not fit: the scene routine whose room it did not fit in (:game for a
          # game with one set), what it needed and what was left.
          Shortfall = Data.define(:scene, :needed, :left)

          # +claims+ in the order the build would pick them, best first; +room+ is the bytes there
          # are for routines; +dispatch+ is the game's scene dispatch, or nil for a game that has
          # none it can swap at.
          def self.choose(claims, room:, dispatch: nil) = Planner.new(claims, room, dispatch).choose

          # The claims by name, so that what a routine adds beside its neighbours can be worked out,
          # and the room there is.
          class Planner
            def initialize(claims, room, dispatch)
              @claims = claims
              @claims_by_name = by_name(claims)
              @room = room
              @dispatch = dispatch if dispatch && dispatch.scenes.size <= SceneQuickMemory::MOST_SETS
            end

            def choose
              insisted, optional = @claims.partition(&:insisted)
              one = one_set
              begin
                one.place_all_insisted!(insisted)
              rescue QuickMemoryFull
                raise unless @dispatch

                # What the author insisted on does not fit in one set for the whole game, so a set
                # per scene is the only way to build the game at all — and where it does not fit
                # there either, the build stops naming the scene.
                return split_better_than(nil, insisted, optional).plan
              end
              one.fill(optional)
              return one.plan if one.missed.empty? || @dispatch.nil?

              (split_better_than(one.plan, insisted, optional) || one).plan
            end

            private

            # WHAT ONE SET LEFT OUT, a scene's own room may hold. Answers the split, or nil where it
            # is no better than +one+ set: it keeps nothing in a scene's set, or it leaves out
            # something every frame runs that one set kept. With no +one+ — what the author
            # insisted on fits only in a split — the split is the answer, and a split that cannot
            # hold what was insisted on stops the build.
            #
            # WHICH ROUTINES GO FIRST is tried two ways when each scene's work was measured, and the
            # one that leaves more of the scenes' measured work in the quick memory is kept. Added
            # up over every scene, a routine two scenes run reads dearer than either scene's own
            # busier routine, though a frame of either spends less in it; taken by what one scene
            # spends, a routine five scenes run loses its room to one scene's own routine that is
            # barely busier. Neither order is right for every game, and filling is cheap enough to
            # do twice.
            def split_better_than(one, insisted, optional)
              orders = [optional]
              orders << by_busiest_scene(optional) if optional.any? { |claim| claim.scene_work&.any? }
              orders.uniq.filter_map { |order| split_in_order(one, insisted, every_frame_first(order)) }
                    .max_by { |split| scene_work_kept(split.plan) }
            end

            # WHAT EVERY FRAME RUNS GOES FIRST in a split, whichever order it is taken in. A routine
            # kept for the whole game needs its room in every scene: taken in the order of what was
            # measured, a menu's own big routine came before the game loop, its set left no room in
            # that scene, and the game loop ran from the cartridge everywhere, play included. And
            # measured per scene the game loop reads cheap, since each scene's frame spends most of
            # its time somewhere else, though it is the one routine every scene runs.
            def every_frame_first(claims) = claims.partition(&:every_frame).flatten

            # +claims+ by the most a frame of any one scene was measured to spend in each, dearest
            # first; those never measured last, in the order given.
            def by_busiest_scene(claims)
              measured, unmeasured = claims.partition(&:scene_work)
              measured.sort_by { |claim| [-(claim.scene_work.values.max || 0), claim.name.to_s] } + unmeasured
            end

            # For each scene with a set, what a frame of it spends in the routines kept for the whole
            # game and in its own set, added up over the scenes.
            def scene_work_kept(plan)
              plan.sets.sum do |scene, names|
                (plan.resident.to_a + names).sum { |name| @claims_by_name[name].scene_work&.fetch(scene, 0) || 0 }
              end
            end

            def split_in_order(one, insisted, optional)
              split = set_per_scene
              begin
                split.place_all_insisted!(insisted)
              rescue QuickMemoryFull
                raise unless one

                return nil # the words a split costs leave too little for what one set held
              end
              split.fill(optional)
              return split unless one

              plan = split.plan
              return nil if plan.sets.empty?

              # A scene's own every-frame routine is not held to that: in its scene's set it is
              # still in the quick memory whenever it runs.
              every_frame = optional.select { |claim| claim.every_frame && claim.scene.nil? && one.kept?(claim.name) }
              every_frame.all? { |claim| plan.resident.include?(claim.name) } ? split : nil
            end

            def one_set = Layout.new(by_name(@claims), { game: @room }, swaps: false)

            # Each scene's room is what there is, less the words that say which set is in and where
            # the far ones are; the game loop is charged for the swap at its dispatch.
            def set_per_scene
              scenes = @dispatch.scenes
              frame = Placement::FRAME_ROUTINE
              claims = @claims.map do |claim|
                next claim unless claim.name == frame && claim.bytes

                claim.with(bytes: claim.bytes + SceneQuickMemory::DISPATCH_ENTRY_BYTES +
                                  (SceneQuickMemory::DISPATCH_CLAUSE_BYTES * @dispatch.clauses))
              end
              left = @room - (SceneQuickMemory::FAR_WORD_SLACK * scenes.size) - SceneQuickMemory::WHERE_WORD_BYTES
              Layout.new(by_name(claims), scenes.to_h { |scene| [scene, left] }, swaps: true)
            end

            def by_name(claims) = claims.to_h { |claim| [claim.name, claim] }
          end

          # One way of holding the routines, filled as it goes: what is kept for the whole game,
          # each scene's set, and the bytes left in each scene's room. A game that keeps one set
          # has one room, :game.
          class Layout
            def initialize(claims, rooms, swaps:)
              @claims = claims
              @rooms = rooms
              @swaps = swaps
              @resident = Set.new
              @sets = swaps ? rooms.keys.to_h { |scene| [scene, []] } : {}
            end

            def plan
              charged = @claims.transform_values(&:bytes).compact
              [[nil, @resident], *@sets].each do |_, names|
                names.each { |name| charged[name] -= bytes_given_back(@claims.fetch(name), names) }
              end
              Plan.new(resident: @resident, sets: @swaps ? @sets.reject { |_, names| names.empty? } : {},
                       charged: charged, missed: missed)
            end

            # Keep every one of +claims+, which the author insisted on, or stop the build saying which
            # did not fit and where.
            def place_all_insisted!(claims)
              claims.each do |given|
                claim = @claims.fetch(given.name)
                if claim.bytes.nil?
                  raise LoweringError,
                        "#{claim.insisted} asks to keep a routine in the console's quick memory, but nothing " \
                        "calls it, so it never runs. To fix this, call it or remove the routine."
                end
                shortfall = shortfall_placing(claim) or next

                raise QuickMemoryFull, insisted_overflow_message(claim, shortfall)
              end
            end

            # Go down +claims+ keeping each that fits, and AGAIN WHILE ANYTHING WAS ADDED, because
            # what a routine adds depends on what is kept beside it: one turned away near the top
            # can fit once a routine it calls, or one that calls it, has gone in below. Leaves
            # #missed as the claims the last pass turned away, which are those that never fitted.
            def fill(claims)
              loop do
                kept_before = kept_count
                @missed = []
                claims.each do |claim|
                  next if kept?(claim.name)

                  shortfall = shortfall_placing(@claims.fetch(claim.name)) or next
                  @missed << Missed.new(name: claim.name, bytes: shortfall.needed, room: shortfall.left,
                                        scene: (shortfall.scene unless shortfall.scene == :game))
                end
                break if kept_count == kept_before
              end
            end

            # The claims the build wanted and could not fit, each with what it needed and what was
            # left, and the scene whose room it missed (nil for a game with one set).
            def missed = @missed || []

            private

            def kept?(name) = @resident.include?(name) || @sets.any? { |_, names| names.include?(name) }

            def kept_count = @resident.size + @sets.sum { |_, names| names.size }

            # Keep +claim+ if it fits: in its scene's set where there are sets and it has a scene,
            # otherwise for the whole game. Answers the Shortfall where it does not fit, and nil
            # where it was kept.
            #
            # A routine kept for the whole game takes its room in every scene. One in a set takes
            # its code's room in its own scene, and the word saying where it is in every scene: the
            # words are all in the quick memory all the time.
            def shortfall_placing(claim)
              scene = claim.scene if @swaps && @sets.key?(claim.scene)
              if scene
                own = bytes_added_by(claim, @sets.fetch(scene))
                word = SceneQuickMemory::WHERE_WORD_BYTES
                return Shortfall.new(scene, own + word, @rooms.fetch(scene)) if own + word > @rooms.fetch(scene)

                tightest, left = @rooms.min_by { |_, bytes| bytes }
                return Shortfall.new(tightest, word, left) if word > left

                @sets.fetch(scene) << claim.name
                @rooms[scene] -= own
                @rooms.transform_values! { |bytes| bytes - word }
              else
                own = bytes_added_by(claim, @resident)
                tightest, left = @rooms.min_by { |_, bytes| bytes }
                return Shortfall.new(tightest, own, left) if own > left

                @resident << claim.name
                @rooms.transform_values! { |bytes| bytes - own }
              end
              nil
            end

            # A CALL BETWEEN TWO ROUTINES KEPT IN ONE PLACE NEVER GREW, so what +claim+ was charged
            # for each of its calls to a routine in +place+ (itself among them) comes back. Every
            # call is charged as though it crossed, because the charging starts before anything is
            # chosen; but the routines of one place are copied as one block and go on calling each
            # other with the plain jump they were measured with. Keeping MORE routines can only
            # turn more calls plain, never fewer, so nothing given back ever has to be taken away.
            def bytes_given_back(claim, place)
              claim.call_charge * claim.calls.count { |target| place.include?(target) }
            end

            # WHAT KEEPING +claim+ ADDS to a place already holding +kept+: its own charge, less its
            # calls to routines there (or to itself), less what each of them gets back for calling it.
            def bytes_added_by(claim, kept)
              own = bytes_given_back(claim, kept.to_set | [claim.name])
              theirs = kept.sum do |other|
                neighbour = @claims[other]
                other == claim.name || neighbour.nil? ? 0 : neighbour.call_charge * neighbour.calls.count(claim.name)
              end
              claim.bytes - own - theirs
            end

            # Said of code rather than of a routine: a record's word keeps routines the build made
            # for it, which the author never wrote and cannot make smaller.
            def insisted_overflow_message(claim, shortfall)
              scene = shortfall.scene.to_s.delete_prefix(SceneQuickMemory::SCENE_PREFIX)
              where = shortfall.scene == :game ? "That" : "While the #{scene} scene is up, that"
              "#{claim.insisted} asks to keep code in the console's quick memory. #{where} code needs " \
                "#{shortfall.needed} bytes, and only #{[shortfall.left, 0].max} are free. To fix this, use " \
                "fewer variables, or remove `fast: true` from this line or from another one."
            end
          end
        end
      end
    end
  end
end
