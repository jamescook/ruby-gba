# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A one-time-setup footgun, sibling to {SeedInLoop}. `list :name, capacity:`
        # DECLARES a list — you set it up once. Written directly inside a per-frame
        # context (the game loop, a scene, a repeat/every timer) the declaration
        # re-runs every frame and re-creates the list empty each time, so anything
        # pushed onto it that frame is thrown away on the next and its length never
        # grows past what a single frame adds. There's no crash — just a collection
        # that mysteriously refuses to fill.
        #
        # Like the other setup footguns, only an UNCONDITIONAL declaration — a direct
        # statement of the per-frame body — is flagged, so a list created inside a
        # condition (a deliberate reset) is left alone. Reading or changing a list in
        # the loop (push/pop/get) is normal and not a declaration, so it isn't touched.
        class ListInLoop
          include PerFrameScope

          NAME = :list_in_loop

          def detect(program)
            per_frame = per_frame_func_names(program)
            findings = []
            program.each do |node|
              next unless node.kind == :list_new

              container = node.parent
              next unless per_frame_container?(container, per_frame)

              findings << Finding.new(check: NAME, severity: :warning,
                                      message: message_for(node, container), source: node.source)
            end
            findings
          end

          private

          def message_for(node, container)
            "the list :#{node[:name]} is declared inside #{per_frame_where(container)}, so it's " \
              "re-created empty every frame: whatever you push onto it is thrown away on the next " \
              "frame and its length never grows. A list is set up once — declare it in setup (above " \
              "the loop, or outside the scene), then push to and read from it inside the loop."
          end
        end
      end
    end
  end
end
