# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # QUICK MEMORY CHOSEN PER SCENE, AND SWAPPED AS A SCENE TAKES OVER.
        #
        # {Placement} fills the console's quick memory once, for the whole game, and boot copies
        # it in. That is right while everything a game wants there fits. When it does not, the
        # routine left out is often one a screen the player is not looking at would have given
        # its room up for: a title screen's work and the game's work are never wanted at the
        # same moment, because only one scene runs on any pass.
        #
        # So then the room is split in two. What every scene runs — the game loop's own body,
        # the routine the console interrupts into, anything those reach outside a scene — keeps
        # a place for the whole game, as before. The rest of the room is a SET for each scene:
        # the routines only that scene reaches, chosen in the order a frame spends time in them.
        # Every set is copied to the same place, so the room is paid for once, by the biggest.
        #
        # THE SWAP happens at the game's scene dispatch, just before the arriving scene's
        # routine is called: a copy of that scene's set out of the cartridge, by the copying
        # engine. The dispatch is in the game loop's own body, which is never in a set, so no
        # routine that could be copied over is part way through running at that moment. A
        # routine an interrupt can reach is never in a set either, since an interrupt can land
        # in the middle of the copy.
        #
        # A ROUTINE IN A SET RUNS FROM THE CARTRIDGE TOO, where it is written: everything in it
        # that names another place names it by its whole address, and everything inside it is
        # counted from where it is. So a call to it from outside its own set reads a word that
        # says where it is NOW — the quick memory while its scene's set is in, the cartridge
        # otherwise — and the swap writes those words. A routine reached while another scene is
        # up is therefore slower and never wrong: a save the file screen started and play
        # finishes, say.
        module SceneQuickMemory
          include Console::Hardware

          # The routine that copies a set in and says where each routine now is. It is run
          # once per change of scene, so it lives in the cartridge.
          SWAP_ROUTINE = :__swap_quick_memory

          # Which set is in the quick memory now: its number, 0 for none.
          LOADED_SET = :__scene_set_in

          # One word of the quick memory for each routine a set holds: where it is now.
          WHERE_WORD_BYTES = 4

          # WHAT THE DISPATCH GROWS BY, charged to the game loop: once, the few instructions that
          # ask which set is in and call the swap (see #emit_scene_set_entry); and for each
          # clause, the call to them, and a call to the scene that reads where it is rather than
          # jumping straight there. Counted at their dearest, with the words they read far from
          # the base of the variables.
          DISPATCH_ENTRY_BYTES = 80
          DISPATCH_CLAUSE_BYTES = 16

          # A call into a set routine from the game loop that is not the dispatch's — a scene's
          # sprites, written in the gap after each frame — reads its word too, and a word far
          # from the base costs two instructions more than the call was charged. Held back for
          # each scene.
          FAR_WORD_SLACK = 8

          # The scenes in the order the dispatch names them, each with its set's routines,
          # once #choose_scene_sets has split the room. Empty when the game keeps one set.
          def quick_memory_sets = @quick_memory_sets || {}

          def swaps_quick_memory? = !quick_memory_sets.empty?

          # The name a game gave the scene whose routine is +routine+ (`scene :play` is
          # :_scene_play), and whether a routine is a scene's at all.
          SCENE_PREFIX = "_scene_"
          def scene_name(routine) = routine.to_s.delete_prefix(SCENE_PREFIX).to_sym
          def scene_routine?(routine) = routine.to_s.start_with?(SCENE_PREFIX)

          # Each scene's own set, by the scene's name, for the report.
          def scene_sets_by_name = quick_memory_sets.to_h { |scene, names| [scene_name(scene), names] }

          # The set number of scene routine +scene+ (counting from 1), or nil.
          def scene_set_number(scene)
            return nil unless swaps_quick_memory?

            index = quick_memory_sets.keys.index(scene)
            index && (index + 1)
          end

          # Does scene routine +scene+ have routines of its own in a set?
          def scene_keeps_routines?(scene) = !quick_memory_sets.fetch(scene, []).empty?

          # Is +node+ the dispatch that swaps?
          def swaps_at?(node) = swaps_quick_memory? && node.equal?(@quick_memory_dispatch)

          # The number of the set +name+ is copied in with, or nil for a routine in no set.
          def set_holding(name) = (@set_of_routine || {})[name]

          private

          # THE GAME'S SCENE DISPATCH, if it has one this can swap at: a `case_var` written in
          # the game loop's own body whose every clause names a scene. A dispatch anywhere else
          # could be inside a routine a set holds, and copying over it there would copy over
          # the code doing the copying.
          def quick_memory_dispatch(program)
            loop_node = frame_body(program) or return nil
            loop_node.walk.find do |node|
              node.kind == :case && node.clauses.size >= 2 &&
                node.clauses.all? { |_, target| scene_routine?(target) }
            end
          end

          # WHO RUNS EACH ROUTINE: the scene routines whose frames reach it, and :frame and :irq
          # for the game loop outside its scenes and the console's interrupt. Only a routine
          # exactly one scene reaches can go in a set. A routine nothing here reaches — one the
          # build calls for itself from places the tree does not show — is said to be the
          # frame's, which keeps it out of every set.
          def scene_owners(program, scenes)
            bodies = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            owners = Hash.new { |hash, key| hash[key] = Set.new }
            mark = lambda do |root, owner, stop|
              seen = Set.new
              visit = lambda do |node|
                callees_of(node).each do |name|
                  next if stop.include?(name) || seen.include?(name)

                  seen << name
                  owners[name] << owner
                  body = bodies[name] and visit.call(body)
                end
              end
              visit.call(root) if root
            end
            mark.call(frame_body(program), :frame, scenes.to_set)
            scenes.each do |scene|
              owners[scene] << scene
              mark.call(bodies[scene], scene, Set.new)
            end
            irq_bodies(program).each { |body| mark.call(body, :irq, Set.new) }
            owners[Placement::FRAME_ROUTINE] << :frame
            owners[Placement::IRQ_ROUTINE] << :irq
            scene_routines.each { |routine, scene| owners[routine] << (scenes.include?(scene) ? scene : :frame) }
            routines_placed_with_frame.each { |routine| owners[routine] << :frame }
            # A routine picked by number is reached through a table of addresses, and a table
            # cannot follow a routine about.
            program.walk.each { |node| node.targets.each { |name| owners[name] << :table } if node.kind == :call_one_of }
            owners
          end

          # SPLIT THE ROOM BETWEEN THE WHOLE GAME AND EACH SCENE, when keeping one set for the
          # whole game left something out. +wanted+ is in the order the whole-game choice tried,
          # and +chosen+ what it kept: what the author insisted on, and what every frame runs,
          # are kept for the whole game here as they were there.
          #
          # Answers a {SceneSplit}, or nil when splitting keeps nothing
          # more than one set did, and the game is built as it was.
          #
          # WHICH ROUTINES GO FIRST is tried two ways when the measurement kept each scene's own
          # counts, and the one that leaves more of the scenes' measured work in the quick memory
          # is kept. Added up over every scene, a routine two scenes run reads dearer than either
          # scene's own busier routine, though a frame of either spends less in it; taken by what
          # one scene spends, a routine five scenes run loses its room to one scene's own routine
          # that is barely busier. Neither order is right for every game, and filling the room
          # is cheap enough to do twice.
          def choose_scene_sets(program, wanted, sizes, room, insisted, chosen)
            dispatch = quick_memory_dispatch(program) or return nil
            scenes = dispatch.clauses.map(&:last).uniq
            return nil if scenes.size > MOST_SETS

            frame = Placement::FRAME_ROUTINE
            sizes = sizes.merge(frame => sizes[frame] + DISPATCH_ENTRY_BYTES + (DISPATCH_CLAUSE_BYTES * dispatch.clauses.size)) if sizes[frame]
            room_to_split = RoomToSplit.new(scenes: scenes, owners: scene_owners(program, scenes), sizes: sizes,
                                            room: room, insisted: insisted, chosen: chosen)
            orders = [wanted]
            orders << @routine_profile.order_by_scene_work(wanted) if @routine_profile && !@routine_profile.scenes.empty?
            filled = orders.uniq.filter_map { |order| fill_scene_sets(order, room_to_split) }
            best = filled.max_by { |filling| work_kept_in_scenes(filling) } or return nil

            @quick_memory_dispatch = dispatch
            @quick_memory_sets = best.sets.transform_values(&:to_a)
            @set_of_routine = {}
            @quick_memory_sets.each_with_index do |(_, names), index|
              names.each { |name| @set_of_routine[name] = index + 1 }
            end
            # The sets holding a routine the game loop reaches outside their scene — a save's
            # routines, written a piece a pass whichever screen is up. They go in first at
            # power-on and are kept clear of where the others go (see #place_scene_sets).
            @sets_run_by_loop = @quick_memory_sets.values.each_with_index.filter_map do |names, index|
              index + 1 if names.any? { |name| room_to_split.owners[name].include?(:frame) }
            end
            @passed_over = best.passed_over
            SceneSplit.new(resident: best.resident, sizes: sizes)
          end

          # What a split is worked out from: the scene routines the dispatch names, who runs each
          # routine (see #scene_owners), what each routine is charged, the room there is, and the
          # routines the author insisted on and the whole-game choice kept.
          RoomToSplit = Data.define(:scenes, :owners, :sizes, :room, :insisted, :chosen)

          # One way of filling the room: the routines kept for the whole game, each scene's set,
          # and what was turned away.
          SceneFilling = Data.define(:resident, :sets, :passed_over)

          # HOW MUCH OF THE SCENES' MEASURED WORK A FILLING KEEPS IN THE QUICK MEMORY: for each
          # scene, what a frame of it spends in the routines kept for the whole game and in its
          # own set, added up over the scenes. Nothing without each scene's own counts, when
          # there is only one filling to choose from.
          def work_kept_in_scenes(filling)
            counts_by_scene = @routine_profile&.scenes || {}
            filling.sets.sum do |scene, set|
              counts = counts_by_scene.fetch(scene_name(scene), {})
              (filling.resident.to_a + set.to_a).sum { |name| counts.fetch(name, 0) }
            end
          end

          # FILL THE ROOM taking +wanted+ in that order. Answers a {SceneFilling}, or nil when
          # the filling is no split worth having.
          def fill_scene_sets(wanted, room_to_split)
            room_to_split => { scenes:, owners:, sizes:, room:, insisted:, chosen: }
            only_scene = ->(name) { (o = owners[name]).size == 1 && scenes.include?(o.first) ? o.first : nil }
            rooms = scenes.to_h { |scene| [scene, room - (FAR_WORD_SLACK * scenes.size) - 4] }
            resident = Set.new
            sets = scenes.to_h { |scene| [scene, Set.new] }
            passed_over = []
            # Keep +name+ in +scene+'s set, or for the whole game when +scene+ is nil, if it
            # fits; answers whether it was kept.
            place = lambda do |name, scene|
              # A routine kept for the whole game takes its room in every scene. One in a set
              # takes its code's room in its own scene, and the word saying where it is in every
              # scene: the words are all in the quick memory all the time.
              own = scene ? bytes_added_by(name, sets[scene], sizes) : bytes_added_by(name, resident, sizes)
              everywhere = scene ? WHERE_WORD_BYTES : own
              left_here = scene ? rooms[scene] : rooms.values.min
              if scene && own + everywhere > left_here
                passed_over << passed_over_note(name, adds: own + everywhere, room: left_here, scene: scene)
                next false
              end
              if everywhere > rooms.values.min
                # What did not fit is in the scene with the least room left: the routine's word,
                # or the whole routine kept for the whole game.
                tightest, left = rooms.min_by { |_, left_there| left_there }
                passed_over << passed_over_note(name, adds: everywhere, room: left, scene: scene && tightest)
                next false
              end

              (scene ? sets[scene] : resident) << name
              rooms[scene] -= own if scene
              rooms.transform_values! { |left| left - everywhere }
              true
            end
            placed = ->(name) { resident.include?(name) || sets.any? { |_, set| set.include?(name) } }

            # WHAT EVERY SCENE RUNS GOES FIRST. Taken in the order of what was measured, a menu's
            # own big routine came before the game loop — and a routine kept for the whole game
            # needs its room in every scene, so the menu's set left none in that scene and the
            # game loop ran from the cartridge everywhere, play included.
            first = wanted & every_frame_routines
            first.each { |name| place.call(name, nil) }
            # Then what the author insisted on, where its scenes run it: a save record's routines
            # go with the scene that asks for the save, though every pass of the game loop can
            # reach them, since a save is written a piece a pass and finishes wherever it is.
            insisted.each do |name|
              place.call(name, only_scene.call(name) || asking_scene(name, owners, scenes)) if sizes[name] && !placed.call(name)
            end
            # A split that cannot keep what the author insisted on is no answer.
            return nil unless insisted.all? { |name| sizes[name].nil? || placed.call(name) }

            loop do
              placed_before = resident.size + sets.sum { |_, set| set.size }
              passed_over = []
              wanted.each { |name| place.call(name, only_scene.call(name)) unless placed.call(name) }
              break if resident.size + sets.sum { |_, set| set.size } == placed_before
            end
            return nil if sets.values.all?(&:empty?)
            # ...and a split that cannot keep what one set for the whole game kept of it is no
            # split worth having: the game is built as it was.
            return nil unless (chosen & every_frame_routines).all? { |name| resident.include?(name) }

            SceneFilling.new(resident: resident, sets: sets, passed_over: passed_over)
          end

          # What splitting the room settled: the routines kept for the whole game, and what each
          # routine is charged — the game loop now for the swap at its dispatch as well.
          SceneSplit = Data.define(:resident, :sizes)

          # THE ONE SCENE THAT ASKS FOR A SAVE OF THE RECORD +name+ BELONGS TO, for a routine of a
          # save record; nil for any other routine, or for a record more than one scene saves.
          # A scene asks when it reaches any routine of that record: the job a save starts is
          # one, and the routines that write the save are run afterwards by the game loop.
          def asking_scene(name, owners, scenes)
            kind, parts = Messages::MadeNames.read(name)
            return nil unless kind == :save_record

            askers = owners.each_with_object(Set.new) do |(routine, who), found|
              other_kind, other_parts = Messages::MadeNames.read(routine)
              found.merge(who & scenes) if other_kind == :save_record && other_parts[:record] == parts[:record]
            end
            askers.size == 1 ? askers.first : nil
          end

          # A routine turned away from +scene+'s set (nil: from the room kept for the whole
          # game), with what a frame was measured to spend in it, for the report and the warning
          # that reads it.
          def passed_over_note(name, adds:, room:, scene:)
            Placement::PassedOver.new(name: name, bytes: adds, room: room, measured: @routine_profile&.busiest_share_of(name),
                                      scene: scene && scene_name(scene))
          end

          public

          # Emit the routine the console interrupts into, so that a call from it to a routine a
          # set holds can be refused (see #refuse_interrupt_call_into_set!).
          def while_emitting_interrupt
            @emitting_interrupt = true
            yield
          ensure
            @emitting_interrupt = false
          end

          # AN INTERRUPT CAN LAND WHILE THE SWAP IS COPYING, so a routine it reaches can never be
          # in a set: it would run half of one scene's code and half of another's. The chooser
          # keeps out every routine the program shows an interrupt reaching; this is what stops
          # one it cannot see — a routine the build calls for itself — rather than guessing.
          def refuse_interrupt_call_into_set!(name)
            return unless @emitting_interrupt && set_holding(name)

            raise LoweringError, "the routine that answers the display calls #{name.inspect}, which is " \
                                 "copied in only while its scene is up. This is a fault in ruby-gba, not " \
                                 "in the game. To build the game now, build with `fast_code: false`."
          end

          # WHERE A ROUTINE IN A SET IS NOW, as a variable of the quick memory: written by the
          # swap, read by every call to it from outside its set.
          def where_word(name) = :"__where_#{name}"

          # The routines a set holds, in the order their words sit in memory.
          def routines_in_sets = quick_memory_sets.values.flatten

          # Give every routine's word its place, side by side, before anything else names a
          # variable that has not got one — so the swap can write them all in one copy.
          def allocate_where_words
            return unless swaps_quick_memory?

            var_addr(LOADED_SET)
            addresses = routines_in_sets.map { |name| var_addr(where_word(name)) }
            return if addresses.each_cons(2).all? { |a, b| b == a + WHERE_WORD_BYTES }

            raise LoweringError, "the words that say where each scene's routines are did not land side by " \
                                 "side. This is a fault in ruby-gba, not in the game. To build the game now, " \
                                 "build with `fast_code: false`."
          end

          # Emit each scene's set as a block of its own, after the whole game's: written to run
          # from the place every set is copied to, and from where it sits in the cartridge.
          def emit_scene_sets
            quick_memory_sets.each_with_index do |(_, names), index|
              number = index + 1
              place_label(set_start_label(number))
              @emitting_hot = true
              @emitting_region = number
              names.each { |name| @functions.emit_one_function(name, @functions.funcs.fetch(name)) }
              @emitting_hot = false
              @emitting_region = nil
              place_label(set_end_label(number))
            end
          end

          # Where set +number+'s block starts and stops in the cartridge. Not "_end": a label and
          # the same name with _end are read as one routine by the profile (see
          # GBA#lowered_routine_addresses), and a whole set is not one.
          def set_start_label(number) = :"__scene_set_code_#{number}"
          def set_end_label(number) = :"__scene_set_code_#{number}_last"

          # How big each set's block came out, by number.
          def set_bytes(number) = @emit.labels.fetch(set_end_label(number)) - @emit.labels.fetch(set_start_label(number))

          def set_numbers = (1..quick_memory_sets.size)

          # The room the sets are copied into: as big as the biggest of them.
          def biggest_set_bytes = set_numbers.map { |number| set_bytes(number) }.max.to_i

          # WHERE IN THAT ROOM EACH SET GOES. Sets small enough to sit side by side are given
          # places that do not overlap, so copying one in leaves the other in: a game's logos and
          # title, with a routine or two of their own, then leave the file screen's routines in
          # quick memory through the opening, where the file screen's saves are checked. Only a
          # set that overlaps another puts it out. Biggest first, each at the place that overlaps
          # the fewest sets the game loop runs (see #choose_scene_sets) — those are what an
          # opening needs left in — then the fewest sets of any kind, then the lowest place.
          def place_scene_sets
            room = biggest_set_bytes
            @set_offsets = {}
            set_numbers.sort_by { |number| [-set_bytes(number), number] }.each do |number|
              size = set_bytes(number)
              places = @set_offsets.map { |other, at| at + set_bytes(other) }.unshift(0).uniq.select { |at| at + size <= room }
              @set_offsets[number] = places.min_by do |at|
                hit = @set_offsets.select { |other, there| stretches_overlap?(at, size, there, set_bytes(other)) }.keys
                [(hit & sets_run_by_loop).size, hit.size, at]
              end
            end
          end

          def sets_run_by_loop = @sets_run_by_loop || []

          def stretches_overlap?(at, size, other_at, other_size) = at < other_at + other_size && other_at < at + size

          # The sets that copying set +number+ in puts out.
          def sets_put_out_by(number)
            set_numbers.select do |other|
              other != number &&
                stretches_overlap?(@set_offsets.fetch(number), set_bytes(number), @set_offsets.fetch(other), set_bytes(other))
            end
          end

          # Each set's bit in the word saying which sets are in. None for "no set".
          def set_bit(number) = number.zero? ? 0 : 1 << number

          # A word has a bit for each set, so a game gets as many sets as that, less "no set".
          MOST_SETS = 31

          # Where a routine in a set runs while its set is in: where the sets are copied to,
          # plus its set's place there, plus how far into its own set it sits.
          def swapped_address(name)
            number = set_holding(name)
            @swap_base + @set_offsets.fetch(number) +
              (@emit.labels.fetch(@functions.func_label(name)) - @emit.labels.fetch(set_start_label(number)))
          end

          # THE TABLES THE SWAP READS. For no set and for each set, a list of what to do, kept in
          # the cartridge: which sets stay in, this set's bit, and then each copy to make — the
          # set's code to its place, its routines' words saying the quick memory, and the words of
          # each set it puts out saying the cartridge again. Each copy is the copying engine's
          # three numbers. "No set", at power-on, makes one copy: every word saying the cartridge.
          QUICK_TABLE = :__scene_set_table

          def register_quick_tables
            return unless swaps_quick_memory?

            @emit.data_blobs[QUICK_TABLE] = "\x00".b * (WHERE_WORD_BYTES * (quick_memory_sets.size + 1))
            register_where_word_tables
            (0..quick_memory_sets.size).each do |number|
              copies = number.zero? ? [word_copy(:all, routines_in_sets)] : copies_for_set(number)
              blob = :"__scene_set_jobs_#{number}"
              keep = number.zero? ? 0 : ~sets_put_out_by(number).sum { |other| set_bit(other) } & 0xFFFF_FFFF
              register_word_blob(blob, [-> { keep }, -> { set_bit(number) }, -> { copies.size }] + copies.flatten)
              @emit.link_data(QUICK_TABLE, number * WHERE_WORD_BYTES, blob)
            end
          end

          # The copies set +number+ makes as it goes in, each as the engine's three numbers. A set
          # with nothing in it makes none: the engine reads a count of nothing as the most it can
          # move, and the swap never asks for such a set anyway (see #scene_keeps_routines?).
          def copies_for_set(number)
            names = quick_memory_sets.values[number - 1]
            return [] if names.empty?

            code = [-> { @emit.label_address(set_start_label(number)) },
                    -> { @swap_base + @set_offsets.fetch(number) },
                    -> { set_bytes(number) / 4 | DMA_32BIT | DMA_ENABLE }]
            put_out = sets_put_out_by(number).filter_map do |other|
              others = quick_memory_sets.values[other - 1]
              word_copy(other, others) unless others.empty?
            end
            [code, word_copy(:"in_#{number}", names), *put_out]
          end

          # A copy of the words of +names+ from table +which+ (see #register_where_word_tables) into
          # their places in the quick memory.
          def word_copy(which, names)
            [-> { @emit.data_address(:"__scene_set_words_#{which}") },
             -> { var_addr(where_word(names.first)) },
             -> { names.size | DMA_32BIT | DMA_ENABLE }]
          end

          # THE WORDS EACH COPY READS: every routine at its place in the cartridge, each set's
          # routines at their place in the quick memory, and each set's at the cartridge.
          def register_where_word_tables
            cartridge = ->(name) { -> { @emit.label_address(@functions.func_label(name)) } }
            register_word_blob(:__scene_set_words_all, routines_in_sets.map(&cartridge))
            quick_memory_sets.values.each_with_index do |names, index|
              register_word_blob(:"__scene_set_words_in_#{index + 1}", names.map { |name| -> { swapped_address(name) } })
              register_word_blob(:"__scene_set_words_#{index + 1}", names.map(&cartridge))
            end
          end

          # A table in the cartridge of words worked out once everything has its place.
          def register_word_blob(blob, values)
            @emit.data_blobs[blob] = "\x00".b * (WHERE_WORD_BYTES * values.size)
            values.each_with_index do |value, i|
              @emit.fixups << Emit::BlobWord.new(kind: :quick_word, blob: blob, offset: i * WHERE_WORD_BYTES, target: value)
            end
          end

          def resolve_quick_word(fix)
            @emit.patch_word(fix.blob, fix.offset, fix.target.call)
          end

          # AT POWER-ON every word says the cartridge, and then each set that has routines goes
          # in — those the game loop runs first, then the rest in the order the dispatch names
          # their scenes — unless it would put out one already in, so the opening runs with as
          # many sets in as sit side by side. Which those are is known only once every set's code
          # is written, so power-on calls a routine of its own, written with the swap.
          POWER_ON_ROUTINE = :__swap_quick_memory_at_power_on

          def emit_call_power_on_swap
            emit_call_cold_routine(POWER_ON_ROUTINE) if swaps_quick_memory?
          end

          def emit_power_on_routine
            place_label(POWER_ON_ROUTINE)
            emit(ASM.push(14))
            [0, *power_on_sets].each do |number|
              emit(ASM.load_immediate(ACC, number))
              emit_branch(:bl, SWAP_ROUTINE)
            end
            emit(ASM.pop(15))
          end

          # The sets the game loop runs go first, whatever order the dispatch names their scenes in.
          def power_on_sets
            (sets_run_by_loop + (set_numbers.to_a - sets_run_by_loop)).each_with_object([]) do |number, chosen|
              next if quick_memory_sets.values[number - 1].empty?

              chosen << number if chosen.none? { |other| sets_put_out_by(number).include?(other) }
            end
          end

          # BEFORE THE DISPATCH CALLS A SCENE, its set is copied in unless it is in already. That
          # is asked by a few instructions written once, at the top of the dispatch and jumped
          # over, which each clause calls with its set's number in r0 — so a clause grows by two
          # instructions however many scenes there are, where asking in each clause cost the
          # game loop its whole question every time. Answers the label the clauses call.
          def emit_scene_set_entry
            entry = @emit.gensym
            over = @emit.gensym
            emit_branch(:b, over)
            place_label(entry)
            emit(ASM.push(14))
            bit = 2
            @primitives.load_var(TMP, LOADED_SET)
            emit(ASM.load_immediate(bit, 1))
            emit(ASM.mov_reg_lsl_reg(bit, bit, ACC))                 # this set's bit
            emit(ASM.and_reg(bit, TMP, bit))
            emit(ASM.cmp_imm(bit, 0))
            done = @emit.gensym
            emit_branch(:bcond, done, cond: :ne)                     # in already
            emit_call_cold_routine(SWAP_ROUTINE)
            place_label(done)
            emit(ASM.pop(15))
            place_label(over)
            entry
          end

          # The registers the swap works in, beside r0 (the set's number, then the word saying
          # which sets are in, then the engine's numbers) and r1 (the copying engine's own
          # address): the set's list of what to do, and how many copies are left in it.
          SWAP_TABLE = 12 # ADDR, which is not defined yet when this file loads
          SWAP_LIST = 2
          SWAP_LEFT = 3

          # THE SWAP, with the set's number in r0: say which sets are in now, then make the
          # copies its list holds (see #register_quick_tables). Uses r0 to r3 and r12, and
          # returns to where it was called from.
          #
          # The code goes in before the words saying where it is, so for the moment between the
          # copies some words point at the new set's code. Nothing runs in that moment but this
          # routine and an interrupt, and nothing an interrupt reaches is in a set (see
          # #refuse_interrupt_call_into_set!), so no call reads a word then.
          def emit_swap_routine
            return unless swaps_quick_memory?

            place_scene_sets # every set's code is written, so their sizes and places are known
            place_label(SWAP_ROUTINE)
            @emit.emit_load_data_address(SWAP_TABLE, QUICK_TABLE)
            emit(ASM.ldr_reg_lsl(SWAP_LIST, SWAP_TABLE, ACC, 2))      # this set's list
            @primitives.load_var(ACC, LOADED_SET)
            emit(ASM.ldr(SWAP_LEFT, SWAP_LIST))                       # the sets that stay in...
            emit(ASM.and_reg(ACC, ACC, SWAP_LEFT))
            emit(ASM.ldr_offset(SWAP_LEFT, SWAP_LIST, 4))             # ...and this one
            emit(ASM.orr_reg(ACC, ACC, SWAP_LEFT))
            @primitives.store_var(ACC, LOADED_SET)
            emit(ASM.ldr_offset(SWAP_LEFT, SWAP_LIST, 8))             # how many copies
            emit(ASM.add_imm(SWAP_LIST, SWAP_LIST, 12))
            again = @emit.gensym
            done = @emit.gensym
            place_label(again)
            emit(ASM.cmp_imm(SWAP_LEFT, 0))
            emit_branch(:bcond, done, cond: :eq)
            @primitives.emit_start_copy_engine(from: -> { emit(ASM.ldr(ACC, SWAP_LIST)) },
                                               to: -> { emit(ASM.ldr_offset(ACC, SWAP_LIST, 4)) },
                                               control: -> { emit(ASM.ldr_offset(ACC, SWAP_LIST, 8)) })
            emit(ASM.add_imm(SWAP_LIST, SWAP_LIST, 12))
            emit(ASM.sub_imm(SWAP_LEFT, SWAP_LEFT, 1))
            emit_branch(:b, again)
            place_label(done)
            emit(ASM.bx(14))
            emit_power_on_routine
            place_label(:"#{SWAP_ROUTINE}_end")
          end

          # What a reader of the running cartridge needs to name a routine that ran from where
          # the sets are copied to (see Cartridge::BuildRecord::SceneSets). Nil for a game that
          # swaps nothing.
          def scene_sets_record
            return nil unless swaps_quick_memory?

            scenes = quick_memory_sets.keys.each_with_index.to_h { |scene, index| [scene_name(scene), index + 1] }
            routines = (1..quick_memory_sets.size).to_h do |number|
              names = quick_memory_sets.values[number - 1]
              [number, names.to_h { |name| [name, swapped_address(name)...(swapped_address(name) + @functions.func_ranges.fetch(name).size)] }]
            end
            RubyGBA::Cartridge::BuildRecord::SceneSets.new(loaded_at: var_addr(LOADED_SET), scenes: scenes, routines: routines)
          end
        end
      end
    end
  end
end
