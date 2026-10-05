# frozen_string_literal: true

require "set"
require_relative "frame_reach"
require_relative "../modes"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A routine the game declares and nothing calls.
        #
        # It still goes in the cartridge — the lowering writes every routine declared — and
        # it never runs. Nothing else says so: the code reads as if it does something, and
        # the screen shows that it does not. The usual cause is a `call` that was never
        # written, or one written to a name spelled another way.
        #
        # Reached means reached from somewhere that runs: anything outside a routine (the
        # main body, the game loop, a timer's handler), and from there every routine a
        # reached one can call. Whatever way a node hands control to a routine, it says so
        # through #callees — a plain `call`, a call picked by number, a call on a variable
        # holding routine names, a scene a `case_var` lands on — so a new way of calling is
        # followed here as soon as its kind answers that. The routines the framework writes
        # and calls for itself are not the author's to hear about, and are left out.
        #
        # A routine called only from one nothing calls is named too: it never runs either.
        # The one exception is a timer's handler, which is its timer's wherever it is
        # written, so its calls count even inside a routine nothing calls — unless a later
        # handler for the same timer replaced it (see Nodes::OnTimer.of).
        class RoutineNeverCalled
          NAME = :routine_never_called
          PLAIN_NAME = "a routine nothing calls"

          def detect(program)
            routines = FrameReach.index_funcs(program)
            reached = reached_routines(program, routines)
            routines.reject { |name, _| reached.include?(name) || made_by_framework?(name) }.map do |name, func|
              Finding.new(check: NAME, severity: :warning, node: func, message: message(name))
            end
          end

          private

          def reached_routines(program, routines)
            reached = Set.new
            handlers = Nodes::OnTimer.of(program).values
            waiting = callees_outside_routines(program.children + handlers.flat_map(&:children))
            until waiting.empty?
              name = waiting.pop
              next if reached.include?(name) || !routines.key?(name)

              reached << name
              waiting.concat(callees_outside_routines(routines.fetch(name).children))
            end
            reached
          end

          # Every routine named by a call in +statements+, not counting the bodies of routines
          # declared among them — a routine runs when it is called, not where it is written.
          # Nor the bodies of timer handlers: those count once each, from the handlers that
          # are really in force, whoever wrote them where.
          def callees_outside_routines(statements)
            statements.reject { |node| %i[func on_timer].include?(node.kind) }.flat_map do |node|
              node.callees + callees_outside_routines(node.statement_bodies)
            end
          end

          def made_by_framework?(name)
            name.to_s.start_with?("__") || !Messages::MadeNames.read(name).nil?
          end

          def message(name)
            scene = Modes.strip_scene_prefix(name)
            if scene != name.to_s
              return "Nothing switches to the scene :#{scene}, so it never runs. It is still in " \
                     "the cartridge. To fix this, add it to a `case_var` with `when_val`, or " \
                     "set a variable to :#{scene} and write `call` with that variable. Or remove " \
                     "the scene."
            end

            "Nothing calls the routine :#{name}, so it never runs. It is still in the cartridge. " \
              "To fix this, write `call :#{name}` where it must run, or remove the routine."
          end
        end
      end
    end
  end
end
