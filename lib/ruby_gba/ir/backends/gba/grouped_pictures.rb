# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # A GAME'S SETS OF PICTURE GROUPS, as the cartridge keeps them (see Builder::PictureGroups).
        #
        # A grouped picture is not kept in sprite memory for its whole scene. It has a place of
        # its own there (see PictureGroupPlaces), the room of each set is kept on the screen the
        # set belongs to — the scene that declared it, or every screen — and between frames, as
        # a group comes up, its pictures are copied out of the cartridge into their places. The
        # copying is a routine of its own for each set, so a profile says what it cost.
        class GroupedPictures
          include Console::Hardware

          # WHAT THE CARTRIDGE NEEDS TO BRING ONE SET'S GROUPS UP while the game runs.
          #
          # +blob+ holds every picture of the set once, back to back. +entries+ is a table of
          # four words for each picture a group holds, group after group: where the picture
          # starts in the blob, where it goes in sprite memory, the copy engine's control word
          # for it, and a word of nothing so an entry is ENTRY_BYTES. +groups_table+ has a word
          # for each of the +group_count+ groups, the number of its first entry and, above
          # COUNT_SHIFT, how many it has. +shown+ holds the groups the game said are up, a word a
          # slot, and +up+ the groups whose pictures are in sprite memory now; the routine copies a
          # group in when it is in the one and not the other, and then makes the two the same.
          # +most_bytes+ is the most one group copies.
          SetCopyPlan = Data.define(:name, :scene, :slots, :group_count, :blob, :entries, :groups_table, :routine,
                                    :shown, :up, :most_bytes)

          COUNT_SHIFT = 16
          ENTRY_BYTES = 16
          ENTRY_SHIFT = 4 # ...so an entry's number shifted this far is where it starts

          # One set's pictures, and where each goes in the set's room.
          Laid = Data.define(:pictures, :places)

          def initialize(program)
            @sets = program.walk.select { |node| node.kind == :picture_groups }
            @laid = {}
          end

          def any? = @sets.any?

          # THE SET A SPRITE'S POSE IS GROUPED BY, or nil: a set of the sprite's own scene or of
          # every screen, which holds the picture in one of its groups. A sprite answers to those
          # sets and no others, the same as the interpreter's check.
          def set_holding(sprite, picture)
            @sets.find do |set|
              (set.scene.nil? || set.scene == sprite.scene) && set.groups_holding(picture).any?
            end
          end

          # WHERE EVERY SET'S PICTURES GO, laid out once every sprite's pictures are encoded. A
          # picture two sprites store alike is one picture to place, in every group either
          # sprite's pose of it is in.
          def place_pictures(pictures)
            @sets.each do |set|
              found = {} # bytes -> [narrow, group numbers]
              pictures.each_value do |sprite|
                sprite.grouped.each do |k, pose|
                  next unless pose.set == set.name

                  narrow, groups = found.fetch(pose.bytes, [true, []])
                  found[pose.bytes] = [narrow && sprite.place.narrow?, groups | set.groups_holding(sprite.node.poses[k])]
                end
              end
              placed = found.map do |bytes, (narrow, groups)|
                PictureGroupPlaces::Picture.new(key: bytes, units: bytes.bytesize / 32, narrow: narrow, groups: groups)
              end
              @laid[set.name] = Laid.new(pictures: placed, places: PictureGroupPlaces.new(placed, together: set.together))
            end
          end

          # The room the sets of +scene+ (nil: every screen) need, by name, in 32-byte units.
          def rooms_on(scene) = @sets.select { |set| set.scene == scene }.to_h { |set| [set.name, @laid.fetch(set.name).places.units] }

          # How far into its set's room the picture +bytes+ goes.
          def offset(name, bytes) = @laid.fetch(name).places.offset(bytes)

          # WHAT THE CARTRIDGE NEEDS FOR EACH SET whose room starts at +bases+[name], given each
          # blob and table to put in the cartridge as they are made.
          def copy_plans(bases, &store)
            @sets.filter_map do |set|
              base = bases[set.name]
              [set.name, copy_plan(set, base, &store)] if base
            end.to_h
          end

          private

          def copy_plan(set, base)
            laid = @laid.fetch(set.name)
            from = {}
            laid.pictures.each { |picture| from[picture.key] = from.sum { |key, _| key.bytesize } }
            entries = []
            groups = set.groups.each_index.map do |number|
              holding = laid.pictures.select { |picture| picture.groups.include?(number) }
              first = entries.length
              holding.each do |picture|
                to = SpriteDrawing::OBJ_TILE_BASE + ((base + laid.places.offset(picture.key)) * 32)
                entries << [from.fetch(picture.key), to, (picture.key.bytesize / 4) | DMA_ENABLE | DMA_32BIT, 0]
              end
              [first | (holding.length << COUNT_SHIFT), holding.sum { |picture| picture.key.bytesize }]
            end
            blob = :"__picture_group_art_#{set.name}"
            yield blob, laid.pictures.map(&:key).join.b
            yield :"#{blob}__entries", entries.flatten.pack("V*")
            yield :"#{blob}__groups", groups.map(&:first).pack("V*")
            SetCopyPlan.new(name: set.name, scene: set.scene, slots: set.slots, group_count: set.groups.length,
                            blob: blob, entries: :"#{blob}__entries", groups_table: :"#{blob}__groups",
                            routine: Messages::MadeNames.make(:picture_groups, set: set.name.to_s),
                            shown: Array.new(set.slots) { |slot| :"__groups_shown_#{set.name}_#{slot}" },
                            up: Array.new(set.slots) { |slot| :"__groups_up_#{set.name}_#{slot}" },
                            most_bytes: groups.map(&:last).max || 0)
          end
        end
      end
    end
  end
end
