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
          DISPATCH_ENTRY_BYTES = 64
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
          def choose_scene_sets(program, wanted, sizes, room, insisted, chosen)
            dispatch = quick_memory_dispatch(program) or return nil
            scenes = dispatch.clauses.map(&:last).uniq
            owners = scene_owners(program, scenes)
            only_scene = ->(name) { (o = owners[name]).size == 1 && scenes.include?(o.first) ? o.first : nil }

            frame = Placement::FRAME_ROUTINE

            sizes = sizes.merge(frame => sizes[frame] + DISPATCH_ENTRY_BYTES + (DISPATCH_CLAUSE_BYTES * dispatch.clauses.size)) if sizes[frame]
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
              if (scene && own + everywhere > left_here) || everywhere > rooms.values.min
                passed_over << passed_over_note(name, scene ? own + everywhere : own, left_here)
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

            @quick_memory_dispatch = dispatch
            @quick_memory_sets = sets.transform_values(&:to_a)
            @set_of_routine = {}
            @quick_memory_sets.each_with_index do |(_, names), index|
              names.each { |name| @set_of_routine[name] = index + 1 }
            end
            @passed_over = passed_over
            SceneSplit.new(resident: resident, sizes: sizes)
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

          # A routine turned away, with what a frame was measured to spend in it, for the report
          # and the warning that reads it.
          def passed_over_note(name, adds, room)
            Placement::PassedOver.new(name: name, bytes: adds, room: room, measured: @routine_profile&.busiest_share_of(name))
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

          def biggest_set_bytes
            (1..quick_memory_sets.size).map { |number| set_bytes(number) }.max.to_i
          end

          # Where a routine in a set runs while its set is in: where the sets are copied to,
          # plus how far into its own set it sits.
          def swapped_address(name)
            number = set_holding(name)
            @swap_base + (@emit.labels.fetch(@functions.func_label(name)) - @emit.labels.fetch(set_start_label(number)))
          end

          # THE TABLE THE SWAP READS: for no set and for each set, where its code is in the
          # cartridge, the copying engine's word for how much of it there is (0 for none), and
          # where the words saying where each routine is are kept for it. And for each, those
          # words: in this set, where the set is copied to; in any other, the cartridge.
          QUICK_TABLE = :__scene_set_table
          QUICK_ENTRY_BYTES = 12

          def register_quick_tables
            return unless swaps_quick_memory?

            names = routines_in_sets
            count = quick_memory_sets.size
            @emit.data_blobs[QUICK_TABLE] = "\x00".b * (QUICK_ENTRY_BYTES * (count + 1))
            (0..count).each do |number|
              blob = :"__scene_set_places_#{number}"
              @emit.data_blobs[blob] = "\x00".b * (WHERE_WORD_BYTES * names.size)
              names.each_with_index do |name, i|
                value = lambda do
                  set_holding(name) == number ? swapped_address(name) : @emit.label_address(@functions.func_label(name))
                end
                @emit.fixups << Emit::BlobWord.new(kind: :quick_word, blob: blob, offset: i * WHERE_WORD_BYTES, target: value)
              end
              entry = number * QUICK_ENTRY_BYTES
              next @emit.link_data(QUICK_TABLE, entry + 8, blob) if number.zero?

              @emit.fixups << Emit::BlobWord.new(kind: :quick_word, blob: QUICK_TABLE, offset: entry,
                                                 target: -> { @emit.label_address(set_start_label(number)) })
              @emit.fixups << Emit::BlobWord.new(kind: :quick_word, blob: QUICK_TABLE, offset: entry + 4,
                                                 target: -> { set_copy_control(number) })
              @emit.link_data(QUICK_TABLE, entry + 8, blob)
            end
          end

          # The copying engine's word for a set: whole words, both ends moving on, and go. A set
          # with nothing in it is 0, which the swap reads as nothing to copy — the engine itself
          # would read a count of 0 as the most it can move.
          def set_copy_control(number)
            words = set_bytes(number) / 4
            words.zero? ? 0 : (words | DMA_32BIT | DMA_ENABLE)
          end

          def resolve_quick_word(fix)
            @emit.patch_word(fix.blob, fix.offset, fix.target.call)
          end

          # At power-on no set is in, and every word says the cartridge.
          def emit_power_on_scene_set
            return unless swaps_quick_memory?

            emit(ASM.load_immediate(ACC, 0))
            emit_call_cold_routine(SWAP_ROUTINE)
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
            @primitives.load_var(TMP, LOADED_SET)
            emit(ASM.cmp_reg(TMP, ACC))
            done = @emit.gensym
            emit_branch(:bcond, done, cond: :eq)
            emit_call_cold_routine(SWAP_ROUTINE)
            place_label(done)
            emit(ASM.pop(15))
            place_label(over)
            entry
          end

          # The registers the swap works in, beside r0 (the set's number, then the engine's
          # numbers) and r1 (the copying engine's own address): the set's row of the table, and
          # the two numbers read out of it for the engine.
          SWAP_ROW = 12 # ADDR, which is not defined yet when this file loads
          SWAP_SOURCE = 2
          SWAP_CONTROL = 3

          # THE SWAP, with the set's number in r0. Uses r0 to r3 and r12, and returns to where
          # it was called from.
          #
          # The code goes in before the words saying where it is, so for the moment between the
          # two copies the old set's words point at the new set's code. Nothing runs in that
          # moment but this routine and an interrupt, and nothing an interrupt reaches is in a
          # set (see #refuse_interrupt_call_into_set!), so no call reads a word then.
          def emit_swap_routine
            return unless swaps_quick_memory?

            place_label(SWAP_ROUTINE)
            @primitives.store_var(ACC, LOADED_SET)
            emit(ASM.lsl_imm(SWAP_SOURCE, ACC, 2))                    # number * 4...
            emit(ASM.lsl_imm(SWAP_CONTROL, ACC, 3))                   # ...plus number * 8, a row being 12
            @emit.emit_load_data_address(SWAP_ROW, QUICK_TABLE)
            emit(ASM.add_reg(SWAP_ROW, SWAP_ROW, SWAP_SOURCE))
            emit(ASM.add_reg(SWAP_ROW, SWAP_ROW, SWAP_CONTROL))       # this set's row
            emit(ASM.ldr(SWAP_SOURCE, SWAP_ROW))                      # where its code is
            emit(ASM.ldr_offset(SWAP_CONTROL, SWAP_ROW, 4))           # how much, as the engine's word
            no_code = @emit.gensym
            emit(ASM.cmp_imm(SWAP_CONTROL, 0))
            emit_branch(:bcond, no_code, cond: :eq)
            @primitives.emit_start_copy_engine(
              from: Primitives::InRegister.new(SWAP_SOURCE),
              to: lambda do
                @emit.fixups << Emit::AddressLoad.new(pos: pos, kind: :quick_base, reg: ACC, target: nil)
                emit(ASM.load_immediate_fixed(ACC, 0))
              end,
              control: Primitives::InRegister.new(SWAP_CONTROL)
            )
            place_label(no_code)
            emit(ASM.ldr_offset(SWAP_SOURCE, SWAP_ROW, 8))            # where its words are
            words = routines_in_sets.size
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(SWAP_SOURCE),
                                               to: var_addr(where_word(routines_in_sets.first)),
                                               control: words | DMA_32BIT | DMA_ENABLE)
            emit(ASM.bx(14))
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

          def resolve_quick_base(fix)
            @emit.patch16(fix.pos, ASM.load_immediate_fixed(fix.reg, @swap_base))
          end
        end
      end
    end
  end
end
