# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A GAME'S SETS OF PICTURE GROUPS, as the cartridge keeps them (see Builder::PictureGroups).
        #
        # A grouped picture is not kept in sprite memory for its whole scene. It has a place of
        # its own there (see IR::PictureGroupPlaces), the room of each set is kept on the screen the
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

          # One set's pictures, where each goes in the set's room, and the bytes each picture name
          # the set's sprites show was stored as.
          Laid = Data.define(:pictures, :places, :bytes_of)

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
              bytes_of = {}
              pictures.each_value do |sprite|
                sprite.grouped.each do |k, pose|
                  next unless pose.set == set.name

                  picture = sprite.node.poses[k]
                  bytes_of[picture] ||= pose.bytes
                  narrow, groups = found.fetch(pose.bytes, [true, []])
                  found[pose.bytes] = [narrow && sprite.place.narrow?, groups | set.groups_holding(picture)]
                end
              end
              placed = found.map do |bytes, (narrow, groups)|
                IR::PictureGroupPlaces::Picture.new(key: bytes, units: bytes.bytesize / 32, even_start: !narrow, groups: groups)
              end
              @laid[set.name] = Laid.new(pictures: placed, places: IR::PictureGroupPlaces.new(placed, together: set.together),
                                         bytes_of: bytes_of)
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

          # THE SETS UP ON +scene+ (nil: every screen), the scene's own and every screen's, as the map
          # of sprite memory says them, for the sets whose rooms start at +bases+[name].
          def map_entries(scene, bases)
            sets_up_on(scene).filter_map do |set|
              base = bases[set.name]
              map_entry(set, base) if base
            end
          end

          # The bytes the rooms of the sets up on +scene+ take.
          def room_bytes_on(scene) = sets_up_on(scene).sum { |set| room_units(set) * 32 }

          # A set's worst set of groups up together, for the words of a build that stops on sprite
          # memory: the set's name, the groups, their pictures' bytes, the room the set takes, and
          # the biggest of those pictures by name, with their bytes.
          WorstSet = Data.define(:name, :groups, :bytes, :room_bytes, :biggest)

          # THE SET UP ON +scene+ WHOSE ROOM IS BIGGEST, with its worst set (see WorstSet), or nil
          # when no set there has a picture a sprite shows.
          def biggest_set_on(scene)
            set = sets_up_on(scene).select { |candidate| room_units(candidate).positive? }.max_by { |candidate| room_units(candidate) }
            return nil unless set

            places = @laid.fetch(set.name).places
            WorstSet.new(name: set.name, groups: places.worst_set, bytes: places.worst_units * 32,
                         room_bytes: room_units(set) * 32, biggest: biggest_pictures(set, places.worst_set))
          end

          private

          def sets_up_on(scene) = @sets.select { |set| set.scene.nil? || set.scene == scene }

          def room_units(set) = @laid.fetch(set.name).places.units

          # The three biggest pictures of +groups+ of +set+, by name with their bytes, in the order
          # the sprites show them. Two names stored as the same bytes are one picture: the first is named.
          def biggest_pictures(set, groups)
            named = @laid.fetch(set.name).bytes_of.select { |picture, _| set.groups_holding(picture).intersect?(groups) }
            named.uniq { |_, bytes| bytes }.map { |picture, bytes| [picture, bytes.bytesize] }
                 .each_with_index.sort_by { |(_, size), at| [-size, at] }.first(3).map(&:first)
          end

          # The bytes the pictures of +groups+ come to, each picture once.
          def bytes_of_groups(laid, groups) = laid.pictures.sum { |picture| picture.groups.intersect?(groups) ? picture.key.bytesize : 0 }

          def map_entry(set, base)
            laid = @laid.fetch(set.name)
            memory = VBlank::Diagnostics::VideoMemory
            groups = set.groups.each_with_index.filter_map do |pictures, number|
              next unless pictures

              placed = pictures.select { |picture| laid.bytes_of.key?(picture) }
              memory::Group.new(number: number, pictures: pictures, bytes: bytes_of_groups(laid, [number]),
                                places: placed.map { |picture| [picture, base + laid.places.offset(laid.bytes_of.fetch(picture))] })
            end
            memory::PictureGroups.new(
              name: set.name, first_tile: base, tiles: laid.places.units,
              address: SpriteDrawing::OBJ_TILE_BASE + (base * memory::TILE_BYTES), groups: groups,
              up_together: set.together.map { |together| memory::UpTogether.new(groups: together, bytes: bytes_of_groups(laid, together)) },
              worst: memory::UpTogether.new(groups: laid.places.worst_set, bytes: laid.places.worst_units * 32)
            )
          end

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
