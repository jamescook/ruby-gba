# frozen_string_literal: true

module VBlank
  class Builder
    # EFFECTS A GAME WRITES FOR ITSELF.
    #
    # A pack is a module of verbs written in the game's own verbs (see {Effects} for the rule a
    # pack keeps): an iris the way one game draws it, a menu with one game's cursor. The packs
    # ruby-gba ships are every game's, registered once for the whole process. A game's own pack
    # is that game's alone: `uses` gives this build the pack's verbs and nothing else does, so two
    # games built side by side can each have a verb of the same name, and a game built in a
    # Ractor can call one — a module's methods are written in the module, not made from a block
    # at run time, so a Ractor can run them.
    #
    #   module Dungeon::Torch
    #     def light_torch(at:) = spotlight(at: at, radius: 30, dark: 80)
    #   end
    #
    #   VBlank.game "DUNGEON" do
    #     uses Dungeon::Torch
    #     light_torch at: [40, 40]
    #   end
    #
    # The pack's public methods are verbs from that line on, its private ones helpers its verbs
    # call, and any checks it answers with (`def self.checks`) report on this build alone.
    module GameEffects
      # Bring in +packs+, each a module of verbs, for this game alone.
      #
      # @param packs [Array<Module>] the packs, in the order their names are checked
      def uses(*packs)
        packs.each do |pack|
          Effects.refuse_non_module_pack!(pack, "uses")
          next if game_packs.include?(pack)

          # Every name the pack answers to, those of the modules it includes as well.
          (pack.public_instance_methods + pack.private_instance_methods).each do |name|
            refuse_taken_pack_name!(pack, name)
          end
          extend(pack)
          @game_packs = game_packs + [pack]
        end
        nil
      end

      # The checks this game's own packs bring, for the build to run beside its own.
      def game_pack_checks = game_packs.flat_map { |pack| Effects.pack_checks(pack) }

      private

      def game_packs = @game_packs || []

      # A name a pack of this game already has, or one ruby-gba has, cannot be taken: the pack
      # would quietly change what a verb the game writes means. Two packs that both include one
      # module have its methods both, and that is one method, not two of the same name.
      def refuse_taken_pack_name!(pack, name)
        owner = pack.instance_method(name).owner
        holder = game_packs.find do |other|
          (other.method_defined?(name) || other.private_method_defined?(name)) &&
            other.instance_method(name).owner != owner
        end
        if holder
          raise Effects::DuplicateVerb,
                "The packs #{holder} and #{pack} both have a verb `#{name}`. A game can use one verb " \
                "of each name. To fix this, rename the verb in one of the packs."
        end
        Effects.refuse_built_in_name!(name)
      end
    end
  end
end
