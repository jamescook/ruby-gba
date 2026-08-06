# frozen_string_literal: true

require_relative "effects/packs/screen_shake"

module RubyGBA
  # The effect registry: how a verb gets added to the DSL from outside the
  # framework. A pack is a bundle of verbs (and, optionally, the guardrails that
  # catch their footguns) that a game can load, or that ships on by default.
  #
  # It is modeled on IR::Guardrails on purpose — a visible frozen list of what is
  # on by default, plus a hook for whatever registers itself at run time — so
  # there is one shape to learn for "what does this build actually have loaded?"
  #
  # == The one rule: a pack composes verbs, it does not add capability
  #
  # A pack may only call PUBLIC DSL verbs. It has no business touching an IR node,
  # a hardware register, or a backend. That is not a style preference, it is what
  # makes a pack free:
  #
  #   - A verb built from public verbs bottoms out in things every backend already
  #     runs, so it works on the GBA and in the reference interpreter the day it is
  #     written, with no per-backend work and no conformance fixture to extend.
  #   - A "pack" that reached into an IR node or a register would need lowering in
  #     every backend, and would break the next one added.
  #
  # So the test is: DOES A BACKEND HAVE TO KNOW ABOUT IT?
  #
  #   No  -> it is a pack. Register it here.
  #   Yes -> it is KERNEL. Bake it into the library: a new IR node kind, its
  #          lowering in each backend, and a conformance fixture entry.
  #
  # Said another way, and this is the quick version to carry around: a KERNEL
  # primitive is a new thing the machine can DO. A pack is a new way to USE what it
  # already does. New capability is kernel; new convenience is a pack. If writing it
  # means opening a file under ir/backends/, it was never a pack.
  #
  # Effects come in PAIRS across that line, and that is the shape to expect — the
  # primitive is one register or one blend, and everything that makes it feel like a
  # game effect is a pack on top:
  #
  #   camera (move the picture)   -> shake_screen  (jitter it, then put it back)
  #   fade   (blend the picture)  -> fade_in/out   (walk the amount over frames)
  #
  # Take the shake. Moving the picture at all is kernel — `camera` is an IR node with
  # a real lowering (the reference point on the hardware, a window offset in the
  # interpreter). Shaking is not: it is `camera` called with a jittering offset, plus
  # four variables and a routine that runs each frame. Nothing there is new
  # capability, so Packs::ScreenShake is written in the same verbs a game is.
  #
  # When a pack turns out to need one small thing the DSL cannot say, the answer is
  # to add that thing as a kernel primitive, not to let the pack reach past the
  # boundary. `each_frame` exists for exactly that reason.
  module Effects
    # Raised when a pack tries to take a verb name that is already in use.
    class DuplicateVerb < StandardError; end

    # The module every registered verb is defined on. Builder includes it, so a
    # pack's verb is an ordinary DSL verb at the call site — a game writes
    # `shake_screen` next to `fill_rect` and cannot tell which is which.
    #
    # Verbs are copied onto this module rather than the pack being included into
    # it, so a verb can be taken off again (Ruby cannot un-include a module).
    VERBS = Module.new

    class << self
      # Add one verb from a block — the quick form, for a verb a single game wants
      # without a pack to put it in.
      #
      #   Effects.register(:flash) { |color| clear_screen color }
      #
      # The block becomes a method on the Builder, so its body is written in plain
      # DSL verbs with no receiver, exactly like the body of a `func`. Returns the
      # verb's name.
      def register(name, &body)
        raise ArgumentError, "Effects.register needs a block: Effects.register(:#{name}) { ... }" unless body

        claim!(name, :inline)
        VERBS.define_method(name, &body)
        @verbs[name] = :inline
        name
      end

      # Add a module of verbs. This is the pack form: several related verbs, their
      # private helpers, and the guardrails for their footguns, in one file that a
      # game (or the framework) loads as a unit.
      #
      # A pack may answer `checks` with a list of whole-program guardrail checks. They
      # are forwarded to IR::Guardrails, so a verb's footguns travel with the verb and
      # are only ever reported for a build that loaded the pack. Cheap argument
      # checking (a length of 0, an unknown name) belongs inline in the verb instead,
      # where it can raise the moment the mistake is written.
      #
      # Registering the same pack twice does nothing the second time. Returns the pack.
      def register_pack(pack)
        unless pack.is_a?(Module) && !pack.is_a?(Class)
          raise ArgumentError,
                "register_effects needs a module of verbs. You gave #{pack.inspect}."
        end
        return pack if @packs.include?(pack)

        verbs = pack.public_instance_methods(false)
        helpers = pack.private_instance_methods(false)
        (verbs + helpers).each { |name| claim!(name, pack) }

        verbs.each { |name| VERBS.define_method(name, pack.instance_method(name)) }
        # A helper comes along too, or the verb that calls it breaks. It is copied
        # private so it never becomes part of the DSL surface by accident.
        helpers.each do |name|
          VERBS.define_method(name, pack.instance_method(name))
          VERBS.send(:private, name)
        end

        verbs.each { |name| @verbs[name] = pack }
        helpers.each { |name| @helpers[name] = pack }
        @packs << pack
        pack_checks(pack).each { |check| IR::Guardrails.register(check) }
        pack
      end

      # Every registered verb, as name => what registered it (the pack module, or
      # :inline for a block). A copy, so the registry stays data a caller can read
      # without being able to change it by accident.
      def verbs
        @verbs.dup
      end

      # The packs loaded right now, in the order they registered.
      def packs
        @packs.dup
      end

      # Take a verb back off the DSL. Returns true if it was registered.
      def unregister(name)
        return false unless @verbs.key?(name)

        VERBS.send(:remove_method, name)
        @verbs.delete(name)
        true
      end

      # Drop everything registered at run time, back to the default packs only —
      # the counterpart of Guardrails.clear_registered!, and for the same reason:
      # so one test's registration cannot leak into the next.
      def clear_registered!
        (@packs - DEFAULT_PACKS).each do |pack|
          pack_checks(pack).each { |check| IR::Guardrails.unregister(check) }
          pack.public_instance_methods(false).each { |name| unregister(name) }
          pack.private_instance_methods(false).each do |name|
            VERBS.send(:remove_method, name) if @helpers[name] == pack
            @helpers.delete(name)
          end
        end
        @packs.select! { |pack| DEFAULT_PACKS.include?(pack) }
        (@verbs.keys - default_verb_names).each { |name| unregister(name) }
        self
      end

      private

      # Refuse a name that something already answers to. Catching it here — as the
      # pack registers, not as the game calls the verb — is what keeps a pack from
      # quietly replacing a framework verb and changing what a program means.
      def claim!(name, owner)
        if (holder = @verbs[name] || @helpers[name])
          return if holder == owner

          raise DuplicateVerb,
                "The verb `#{name}` is already registered by #{holder}. Two packs " \
                "cannot use one name. To fix this, rename the verb in your pack."
        end

        return unless Builder.method_defined?(name) || Builder.private_method_defined?(name)

        raise DuplicateVerb,
              "The name `#{name}` is already used by ruby-gba. A pack cannot replace " \
              "a built-in verb. To fix this, use a different name in your pack."
      end

      def pack_checks(pack)
        pack.respond_to?(:checks) ? Array(pack.checks) : []
      end

      def default_verb_names
        DEFAULT_PACKS.flat_map { |pack| pack.public_instance_methods(false) }
      end
    end

    @verbs = {}
    @helpers = {}
    @packs = []

    # The packs that ship with ruby-gba and are on in every build — the same idea
    # as Guardrails::BUILTIN_CHECKS, and visible data for the same reason. A game
    # gets these verbs without asking for them; anything else it registers itself.
    DEFAULT_PACKS = [
      Packs::ScreenShake, # shake_screen — the impact effect, built on `camera`
    ].freeze
  end

  # Load a pack's verbs into the DSL.
  #
  #   RubyGBA.register_effects(MyStudio::Juice)
  #
  # From then on every build can call that pack's verbs, and any guardrail the pack
  # declares reports on every build. See {Effects} for what a pack is allowed to do.
  def self.register_effects(*packs)
    packs.each { |pack| Effects.register_pack(pack) }
    packs.length == 1 ? packs.first : packs
  end

  # The DSL gains its registered verbs here. Included after Builder's own concerns,
  # but nothing can shadow them: a name already in use is refused at registration.
  Builder.include(Effects::VERBS)
  Effects::DEFAULT_PACKS.each { |pack| Effects.register_pack(pack) }
end
