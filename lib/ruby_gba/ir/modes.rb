# frozen_string_literal: true

module RubyGBA
  module IR
    # Works out which screen mode each scene of a program runs in.
    #
    # A game can put different scenes on screen in different screen modes — a
    # colorful direct-color title, then a tear-free double-buffered play field —
    # and the framework switches the hardware as each scene takes over. Deciding
    # *which* scene draws in *which* mode is pure structural analysis of the
    # program: it doesn't depend on any target machine, so a backend and the
    # cost/palette analyses can all read one answer from here instead of each
    # working it out (and risking a subtle disagreement).
    #
    # A scene declares its mode with a `screen` at its top; with none, it runs in
    # the mode it was reached in. The mode is resolved by following the call graph
    # from the program's per-frame entry points (the scenes a game loop dispatches
    # to), so a helper a scene calls inherits the scene's mode. A drawing routine
    # reached from two different modes can't draw both ways, so that's a friendly
    # error rather than a silently-wrong screen.
    class Modes
      # Raised when one drawing routine is reached from scenes of different modes.
      class Conflict < StandardError; end

      DIRECT = :direct     # single-buffered direct color
      BUFFERED = :buffered # double-buffered, tear-free

      def self.resolve(program)
        new(program)
      end

      # Strip the internal `_scene_` prefix a scene's func carries, so a message or
      # a report shows the name the author actually wrote (`:play`, not
      # `:_scene_play`).
      def self.friendly_name(name)
        name.to_s.sub(/\A_scene_/, "")
      end

      # The boot screen mode: the mode declared at the top level, or :direct.
      attr_reader :default_mode

      # func name -> :direct | :buffered, for every func reachable from an entry
      # point (unreached funcs, which never render, are absent).
      attr_reader :func_mode

      # The funcs the per-frame loop dispatches to, in first-seen order — the
      # points where the hardware mode is switched as a scene takes over.
      attr_reader :scene_funcs

      # Does any scene double-buffer? When false, a program stays entirely on the
      # single-buffered path (no palette, no page flips).
      def any_buffered?
        @default_mode == BUFFERED || @func_mode.value?(BUFFERED)
      end

      # Whether the program mixes modes — some scene direct, some buffered. A
      # single-mode program can be judged as a whole; a mixed one has to be judged
      # scene by scene, since each mode has its own drawing budget.
      def mixed?
        seen = @func_mode.values + [@default_mode]
        seen.include?(DIRECT) && seen.include?(BUFFERED)
      end

      # The resolved mode of a func: what it was reached as, or the boot mode for a
      # func never reached from an entry point.
      def mode_of(name)
        @func_mode.fetch(name, @default_mode)
      end

      # The statement subtrees that draw in buffered mode: the main body when the
      # boot mode is buffered, plus every reachable func resolved to buffered. A
      # consumer that cares only about buffered drawing (the palette, which only
      # exists for the indexed double-buffered screen) walks exactly these, so a
      # direct-color scene's colors never count toward the buffered palette.
      def buffered_scopes
        scopes = []
        scopes.concat(main_body) if @default_mode == BUFFERED
        @funcs.each { |name, func| scopes << func if @func_mode[name] == BUFFERED }
        scopes
      end

      private

      def initialize(program)
        @program = program
        @funcs = {}
        program.walk { |node| @funcs[node[:name]] = node if node.kind == :func }
        @func_mode = {}
        @scene_funcs = []
        @default_mode = declared_mode(main_body) || DIRECT
        entry_targets.each { |target| resolve_func(target, @default_mode, scene: true) }
        @func_mode.freeze
        @scene_funcs.freeze
      end

      def resolve_func(name, inherited, scene:)
        func = @funcs[name] or return
        mode = declared_mode(func.children) || inherited
        @scene_funcs << name if scene && !@scene_funcs.include?(name)

        if @func_mode.key?(name)
          return if @func_mode[name] == mode

          raise Conflict,
                "the drawing routine :#{self.class.friendly_name(name)} is used from both a " \
                "direct-color scene and a double-buffered one — a drawing routine can't be shared " \
                "across screen modes. Give each mode its own routine, or move the shared drawing inline."
        end

        @func_mode[name] = mode
        call_targets(func).each { |target| resolve_func(target, mode, scene: false) }
      end

      # The screen mode a run of statements declares, via a `screen` node among
      # them (nil if none): buffered when the screen opted into double buffering.
      def declared_mode(statements)
        statements.each do |node|
          return node[:buffered] ? BUFFERED : DIRECT if node.kind == :screen
        end
        nil
      end

      # The program's main body — everything except the func definitions appended
      # to the tree (those are separate scenes/helpers, resolved on their own).
      def main_body
        @program.children.reject { |node| node.kind == :func }
      end

      # The funcs the main body dispatches to each frame — case_var scenes and
      # calls in the loop. These are the mode-switch entry points.
      def entry_targets
        main_body.flat_map { |node| call_targets(node) }
      end

      # Every func a node (and its whole subtree, including else-branches) calls or
      # dispatches to.
      def call_targets(node)
        targets = []
        node.walk do |n|
          targets << n[:target] if n.kind == :call
          n[:clauses].each { |_value, target| targets << target } if n.kind == :case
        end
        targets
      end
    end
  end
end
