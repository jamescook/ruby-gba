# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # BRINGING A SET OF PICTURE GROUPS' GROUPS UP, on the console (see GroupedPictures).
        #
        # `show` only writes down which groups the game wants up. Between frames, before the
        # sprites are written, the set's routine copies in the pictures of each group that is
        # wanted and was not up, and nothing else: a room the game stays in costs a compare a slot,
        # and walking into the next costs that room's pictures. A group that stays up as another
        # comes up is never written over, since the two are up together and the places of
        # pictures up together never overlap (see IR::PictureGroupPlaces).
        class PictureGroupCopying
          include Console::Hardware
          include EmitterCalls

          # A group number no group has: nothing is up.
          NONE = IR::Nodes::PictureGroups::NONE

          # The registers the copy walks a group's entries with (see #emit_bring_slot_up).
          PICTURE_TO = 2
          CONTROL = 3
          ENTRY = 4
          LEFT = 5

          def initialize(emitter:, primitives:, lowering:, scene_entry:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @scene_entry = scene_entry
            @plans = {}
          end

          # What each set needs, by its name (see GroupedPictures::SetCopyPlan).
          attr_writer :plans

          # Note which group is wanted up in +node+'s slot. A set no sprite draws from has
          # nothing to bring up, and nothing is written.
          def emit_show_picture_group(node)
            plan = @plans[node.name] or return

            @lowering.value(node.which)
            store_var(ACC, plan.shown.fetch(node.slot))
          end

          # Every set's routine, in the gap before the sprites are written.
          def emit_calls_to_routines
            @plans.each_value { |plan| @lowering.statement(Build.call(plan.routine)) }
          end

          # THE ROUTINE OF ONE SET. A set of a scene's own does nothing while another scene's
          # sprite pictures are up, since its room is theirs then.
          def emit_routine(plan)
            return emit_bring_groups_up(plan) unless plan.scene

            @scene_entry.emit_if_scene_up(:art, plan.scene) { emit_bring_groups_up(plan) }
          end

          # AT POWER-ON no group is wanted and none is up, whatever the memory held: the game says
          # which it wants before its sprites are first drawn.
          def emit_clear_groups_at_power_on
            @plans.each_value { |plan| emit_forget(plan.shown + plan.up) }
          end

          # ON A CHANGE OF SCREEN no group's pictures are in sprite memory, and the groups the game
          # wants are copied in again before the sprites are next written.
          def emit_forget_every_set_up
            @plans.each_value { |plan| emit_forget(plan.up) }
          end

          # AS A SCENE TAKES OVER none of its own groups is up, since another scene's pictures were
          # in their room. The groups it wants are still the ones it wanted as it left, as the
          # interpreter has it, and they are copied in again before its sprites are next written:
          # a scene given the screen back draws its sprites as they were left, and a scene that
          # loads first does so before any of its own code has run to say which groups it wants.
          def emit_forget_sets_of(scene)
            @plans.each_value { |plan| emit_forget(plan.up) if plan.scene == scene }
          end

          # Does +scene+ own a set, which it has to put down as it takes over?
          def sets_of?(scene) = @plans.each_value.any? { |plan| plan.scene == scene }

          private

          def emit_forget(vars) = vars.each { |var| store_word_immediate(NONE, var_addr(var)) }

          # Every group wanted up that no slot had up: what was up is read before anything
          # changes, so a group moving from one slot to another is not copied again.
          def emit_bring_groups_up(plan)
            plan.slots.times { |slot| emit_bring_slot_up(plan, slot) }
            plan.slots.times do |slot|
              load_var(ACC, plan.shown[slot])
              store_var(ACC, plan.up[slot])
            end
          end

          #   r0  the group wanted, then where a picture is in the cartridge
          #   r1  what was up, then a table's address (and the copy engine's)
          #   r2  the group's word, then where a picture goes
          #   r3  the copy engine's control word for it
          #   r4  the group's next entry
          #   r5  how many pictures of the group are left
          def emit_bring_slot_up(plan, slot)
            done = gensym
            again = gensym
            load_var(ACC, plan.shown[slot])
            plan.up.each do |var|
              load_var(TMP, var)
              emit(ASM.cmp_reg(ACC, TMP))
              emit_branch(:bcond, done, cond: :eq) # up already
            end
            # One unsigned compare catches both ends: nothing wanted reads as a very large number.
            emit_number(TMP, plan.group_count)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, done, cond: :hs)
            emit_load_data_address(TMP, plan.groups_table)
            emit(ASM.ldr_reg_lsl(PICTURE_TO, TMP, ACC, 2))
            emit(ASM.lsr_imm(LEFT, PICTURE_TO, GroupedPictures::COUNT_SHIFT))
            emit(ASM.cmp_imm(LEFT, 0))
            emit_branch(:bcond, done, cond: :eq) # a group no sprite shows a picture of
            emit(ASM.lsl_imm(PICTURE_TO, PICTURE_TO, 32 - GroupedPictures::COUNT_SHIFT))
            emit(ASM.lsr_imm(PICTURE_TO, PICTURE_TO, 32 - GroupedPictures::COUNT_SHIFT - GroupedPictures::ENTRY_SHIFT))
            emit_load_data_address(ENTRY, plan.entries)
            emit(ASM.add_reg(ENTRY, ENTRY, PICTURE_TO)) # the group's first entry
            @emitter.note_video_copy("bringing in a group of picture_groups :#{plan.name}", plan.most_bytes)
            place_label(again)
            emit(ASM.ldr_offset(ACC, ENTRY, 0))
            emit_load_data_address(PICTURE_TO, plan.blob)
            emit(ASM.add_reg(ACC, ACC, PICTURE_TO))
            emit(ASM.ldr_offset(PICTURE_TO, ENTRY, 4))
            emit(ASM.ldr_offset(CONTROL, ENTRY, 8))
            emit_start_copy_engine(from: in_register(ACC), to: in_register(PICTURE_TO), control: in_register(CONTROL))
            emit(ASM.add_imm(ENTRY, ENTRY, GroupedPictures::ENTRY_BYTES))
            emit(ASM.subs_imm(LEFT, LEFT, 1))
            emit_branch(:bcond, again, cond: :gt)
            place_label(done)
          end
        end
      end
    end
  end
end
