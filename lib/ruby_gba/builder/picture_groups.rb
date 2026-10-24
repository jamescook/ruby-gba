# frozen_string_literal: true

module RubyGBA
  class Builder
    # A SCENE'S SPRITE PICTURES IN GROUPS, only some of them up at a time. A concern of
    # {Builder}, mixed in so `picture_groups` stays a flat DSL verb.
    #
    # WHY IT EXISTS. The console draws sprites from pictures kept in a memory of their own,
    # 32K of it, and every picture a scene's sprites can show is kept there for as long as the
    # scene is up. A scene made of many rooms shows one room's things at a time — two while the
    # screen slides from one room to the next — but its pools and lists of things can show any
    # room's, so all of them have to fit at once, and a game of twenty rooms runs out long
    # before any one room would. The console's own games load a room's things as the room loads
    # and let them go as it is left. Said here, a game does the same: it groups its pictures by
    # room and says which rooms are up, and only those have to fit.
    module PictureGroups
      # GROUP A SCENE'S SPRITE PICTURES, by room:
      #
      #   rooms = picture_groups :rooms, { 0 => [:pot, :bush], 1 => [:pot, :chest] },
      #                          up_together: [[0, 1]]
      #   rooms.show room                  # this room's things are up
      #   rooms.show room, beside          # ...and the room beside's, while the screen slides
      #
      # A picture in no group is up the whole time — the hero, the panel, the shadows. A
      # picture in a group is up only while one of its groups is, and a sprite drawn showing
      # it at any other moment is a mistake the game is stopped for, on every build, in plain
      # words. Groups that can be up at once say so in +up_together+; without it, one group at
      # a time. As a scene takes over, none of its groups is up until the game says one is.
      #
      # @param name [Symbol] what the groups are called, in errors and reports
      # @param groups [Hash{Integer => Array<Symbol>}] each group's pictures, by its number
      # @param up_together [Array<Array<Integer>>] each set of groups that can be up at once
      # @return [DSL::PictureGroups] the handle to #show groups through
      def picture_groups(name, groups, up_together: [])
        refuse_picture_groups_off_tiles!(name)
        refuse_picture_groups_named_twice!(name)
        refuse_picture_groups_shape!(name, groups, up_together)
        numbered = Array.new(groups.keys.max + 1) { |number| groups[number]&.uniq }
        node = Build.picture_groups(name, groups: numbered, together: up_together.map(&:uniq), scene: declaring_scene)
        record(node)
        @picture_groups[name] = node
        DSL::PictureGroups.new(self, name, slots: node.slots)
      end

      private

      # A screen not drawn from tiles paints its sprites into the picture, from pictures kept in
      # the cartridge: there is no sprite memory for the groups to save.
      def refuse_picture_groups_off_tiles!(name)
        return if Text::TILE_HARDWARE_MODES.include?(@screen_mode)

        raise ArgumentError, "picture_groups :#{name} is on a screen :#{@screen_mode}. That screen paints its sprites " \
                             "into the picture, and has no sprite memory for the groups to save. To fix this, use " \
                             "`screen :tiled`, or take out picture_groups."
      end

      def refuse_picture_groups_named_twice!(name)
        return unless @picture_groups.key?(name)

        raise ArgumentError, "picture_groups :#{name} is declared twice. Each set of groups needs its own name. " \
                             "To fix this, rename one of them."
      end

      def refuse_picture_groups_shape!(name, groups, up_together)
        whole = ->(number) { number.is_a?(Integer) && number >= 0 }
        unless groups.is_a?(Hash) && !groups.empty? && groups.all? { |number, pictures| whole.call(number) && pictures.is_a?(Array) && pictures.all?(Symbol) }
          raise ArgumentError, "picture_groups :#{name} was given #{groups.inspect}. It needs each group's number " \
                               "with the names of its pictures, like `picture_groups :#{name}, { 0 => [:pot], 1 => [:bush] }`."
        end
        unless up_together.is_a?(Array) && up_together.all? { |set| set.is_a?(Array) && set.all?(whole) }
          raise ArgumentError, "picture_groups :#{name} was given up_together: #{up_together.inspect}. It needs " \
                               "sets of group numbers, like `up_together: [[0, 1], [1, 2]]`."
        end

        up_together.flatten.uniq.each do |number|
          next if groups.key?(number)

          raise ArgumentError, "up_together: of :#{name} names group #{number}, and :#{name} has no group #{number}. " \
                               "To fix this, give :#{name} a group #{number}, or take #{number} out of up_together:."
        end
      end

      # ONCE EVERY PICTURE IS DECLARED: every picture a group names is one, checked here and not
      # where the groups are written, since a game may group its pictures before it draws them.
      # And a picture turned with `mirror` or `upside_down` goes in every group its own picture
      # is in: the console draws it from that picture's tiles, turned, so it is up exactly when
      # they are.
      def finalize_picture_groups
        @picture_groups.each_value do |node|
          node.groups.compact.flatten.uniq.each do |picture|
            next if @images.key?(picture)

            raise ArgumentError, "picture_groups :#{node.name} names :#{picture}, which is not a picture. " \
                                 "Declare it with `image :#{picture}, ...`, or correct the name."
          end
          node.groups = node.groups.map { |pictures| pictures && with_turned_forms(pictures) }
        end
      end

      # +pictures+ and every picture made by turning one of them, turned again included.
      def with_turned_forms(pictures)
        found = pictures.dup
        loop do
          turned = @turned_images.filter_map { |(_way, source), name| name if found.include?(source) && !found.include?(name) }
          return found if turned.empty?

          found.concat(turned)
        end
      end
    end
  end
end
