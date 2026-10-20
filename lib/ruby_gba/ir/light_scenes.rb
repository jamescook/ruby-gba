# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH SCENES A GAME'S LIGHT IS OFF IN.
    #
    # A light is a darkening outside a shape, and on a display that mixes the picture as it
    # draws it, the darkening and a see-through layer — or a darkening of its own placed in the
    # stack — ask for the same part of it. That part can be told what to do afresh each frame,
    # though, and a game is only in one scene at a time. So the two can share it by
    # taking turns: in a scene whose screen sees through a layer, or that fades under one, the
    # light is OFF, and in every other scene it is on. A scene that does both — sees through
    # a layer and moves the light — is the one thing that cannot be, and a guardrail says so
    # (see Guardrails::Checks::LightCannotShare).
    #
    # A game with no scenes is one screen, which is dark here only if the light is refused.
    #
    # WHEN IT SWITCHES, on every backend: off on the picture of the pass whose scene has it off,
    # since that scene's own mixing takes the part there and then; on again only from the light
    # worked out in the gap after a lit scene's pass, a picture later, as a moved light is.
    #
    # Every backend reads this, so the scenes the light is off in are decided once.
    module LightScenes
      module_function

      # Why the light is off in each scene it is off in: { scene => SeeThroughLayer node, or a
      # :fade node placed in the stack }. Empty for a game with no light, or one whose light
      # is on everywhere — and for a game with no scenes at all.
      def dark(program)
        return {} unless light_of(program)

        names = scenes(program)
        return {} if names.empty?

        see_through = SeeThrough.layers(program)
        on_screen = Stacking.screenfuls(program).to_h do |screenful|
          [screenful.scene, SeeThrough.on_screen(screenful, see_through).first]
        end
        routines = routines_of(program)
        names.to_h do |scene|
          [scene, on_screen[scene] || statements_run_by(routines, [routines[scene]], names).find { |node| placed_fade?(node) }]
        end.compact
      end

      # The scenes among +dark+ that move the light, each with why it is dark: the scenes a
      # guardrail refuses.
      def dark_scenes_moving_light(program)
        light = light_of(program) or return {}
        names = scenes(program)
        moved = light_vars(light)
        routines = routines_of(program)
        dark(program).select do |scene, _|
          statements_run_by(routines, [routines[scene]], names).any? { |node| writes_any?(node, moved) }
        end
      end

      # A fade placed in the stack by code outside every scene — the game loop, a routine it
      # calls — which is in force whatever scene is up, the light's included. nil for none.
      def placed_fade_outside_scenes(program)
        names = scenes(program)
        routines = routines_of(program)
        outside = program.children.reject { |node| node.kind == :func }
        statements_run_by(routines, outside, names).find { |node| placed_fade?(node) }
      end

      # The variable a game with dark scenes keeps the light switched on or off in, 1 or 0:
      # each scene sets it as it runs, and the light's darkness is that much of what it says.
      ON = :__spotlight_on

      # Does +program+ switch its light as its scenes take turns? Asked of the program itself,
      # by whether anything sets the switch, so a backend handed a program nobody gave a switch
      # — one built by hand — keeps its light on throughout, as it says.
      def switches?(program) = program.walk.any? { |node| node.kind == :set && node.var == ON }

      def light_of(program) = program.walk.find { |node| node.kind == :shade_outside }

      def placed_fade?(node) = node.kind == :fade && !node.under.nil?

      # Every scene the game dispatches to.
      def scenes(program) = Stacking.screenfuls(program).filter_map(&:scene)

      # The variables the light is worked out from — where it is, how big and how dark — read
      # off its own statement, so nothing here has to know what a backend or the builder
      # called them. The row it is worked out for, what it works out once a row on its way to
      # the edges, and the switch the build gives it are the light's own, not the game's.
      def light_vars(light) = (vars_read(light, [light.left, light.right, light.amount, *light.children]) - [ON]).uniq

      # The variables the light's ROWS are worked out from — where it is and how big, but not how
      # dark, which is the same on every row. Rows worked out from the same numbers come out the
      # same, which is what lets a backend keep them from one frame to the next.
      def span_vars(light) = vars_read(light, [light.left, light.right, *light.children]).uniq

      # Every variable read in +parts+ of +light+, but the row it is worked out for and what it
      # works out once a row on its way to the edges, which are its own.
      def vars_read(light, parts)
        nodes = parts.flat_map { |part| part.walk.to_a }
        read = nodes.filter_map { |node| node.kind == :copy ? node.src : (node.name if node.kind == :var_ref) }
        own = light.children.flat_map { |child| child.walk.to_a }.filter_map { |node| written_var(node) }
        read - [light.row, *own]
      end

      # Does the statement +node+ change one of +vars+?
      def writes_any?(node, vars) = vars.include?(written_var(node))

      # The variable the statement +node+ changes, or nil. Every statement that changes one
      # names it as its `var`, but a copy, which names it as where it copies to.
      def written_var(node)
        return unless node.statement?
        return node.dest if node.kind == :copy

        node.var if node.respond_to?(:var)
      end

      def routines_of(program) = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }

      # Every statement under +starts+, and those of every routine they call, except scenes,
      # which run as scenes of their own.
      def statements_run_by(routines, starts, scene_names)
        seen = Set.new
        waiting = starts.compact
        nodes = []
        while (start = waiting.pop)
          start.walk.each do |node|
            nodes << node
            node.callees.each do |name|
              next if scene_names.include?(name) || !seen.add?(name)

              waiting << routines[name] if routines[name]
            end
          end
        end
        nodes
      end
    end
  end
end
