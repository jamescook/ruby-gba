# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # WHAT A PROGRAM RESERVES, against the memory there really is.
        #
        # The console has two work memories: 32K of quick on-chip RAM and 256K of roomier
        # RAM on a chip of its own. A COLLECTION can live in either — the framework puts
        # what a frame touches in the quick one and lets the rest fall into the roomy one
        # — so a program with a lot of state is no longer a build failure just because it
        # will not all fit near to hand.
        #
        # What CANNOT move is a variable. Every variable is reached by naming the base of
        # the quick memory and riding a distance inside the load instruction, which is what
        # makes a variable read two instructions instead of four; a variable in the roomy
        # memory would be neither quick nor near. Nor can a sprite's save-under buffer,
        # which the copying engine streams to and from every frame.
        #
        # So this checks two things, and both are real ceilings rather than budgets anybody
        # chose. What must be in the quick memory has to fit in it. And everything the
        # program declares, together, has to fit in the two memories added up. Past either
        # the build stops with a plain-language error: how much is needed, how much there
        # is, and the biggest users so the fix is obvious.
        class IwramBudget
          NAME = :iwram_budget
          PLAIN_NAME = "the #{PlainWords::QUICK_MEMORY} budget"

          # The GBA's fast RAM is 32KB, but not all of it is free for the program's data:
          # the call stack lives at the top and the framework keeps a little scratch of its
          # own. The usable budget is the total minus a headroom reserve, so staying under
          # it leaves room for both. (A word — a variable or a list slot — is 4 bytes.)
          IWRAM_BYTES = 32 * 1024
          RESERVED_BYTES = 4 * 1024
          BUDGET_BYTES = IWRAM_BYTES - RESERVED_BYTES
          WORD = 4

          # ...and the roomy one, all of which a collection may use.
          EWRAM_BYTES = 256 * 1024

          # How many top users to name in the error — enough to point at the fix,
          # not so many the message becomes a memory dump.
          TOP_USERS = 3

          def detect(program)
            users = contributors(program)
            pinned = users.reject { |user| user[:movable] }.sum { |user| user[:bytes] }
            total = users.sum { |user| user[:bytes] }
            return pinned_too_big(users, pinned) if pinned > BUDGET_BYTES
            return [] if total <= BUDGET_BYTES + EWRAM_BYTES

            # Blame the biggest user, which is the capacity to shrink. The plain
            # variable count and the sprites' save-buffers are sums over the whole
            # program with no one declaration behind them, so a program whose biggest
            # user is one of those blames the program itself.
            [Finding.new(check: NAME, severity: :error, message: message(total, users),
                         node: users.first[:node] || :program)]
          end

          # The things that can only be in the quick memory are over it on their own, and
          # no other memory can take them.
          def pinned_too_big(users, pinned)
            worst = users.reject { |user| user[:movable] }.first
            [Finding.new(check: NAME, severity: :error, node: worst&.dig(:node) || :program,
                         message: pinned_message(pinned, users))]
          end

          private

          # Everything the program reserves IWRAM for, each as { label:, bytes:, node: },
          # largest first — so the message can name the total and point at the biggest
          # users, and the finding can send the author to the biggest one's line.
          def contributors(program)
            items = list_and_pool_items(program)

            var_count = variable_names(program).size
            if var_count.positive?
              items << { label: pluralize(var_count, "variable"), bytes: var_count * WORD,
                         node: nil, movable: false }
            end

            buffers = backing_bytes(program)
            if buffers.positive?
              items << { label: "sprite save-buffers", bytes: buffers, node: nil, movable: false }
            end

            items.sort_by { |item| -item[:bytes] }
          end

          # Lists as contributors — but a pool's several backing lists collapse into one
          # "pool :name" (the author declared one pool, not five lists), while a standalone
          # list stays "list :name". The node kept under a label is its first declaration,
          # which is the line the author wrote.
          def list_and_pool_items(program)
            grouped = {}
            list_declarations(program).each do |name, (bytes, node)|
              item = (grouped[label_for(name)] ||= { label: label_for(name), bytes: 0,
                                                     node: node, movable: true })
              item[:bytes] += bytes
            end
            grouped.values
          end

          # name => [bytes, node] for every list the program creates (deduped by name — a
          # list re-declared to reset it reserves its storage once). A list is its
          # `capacity` slots plus two hidden bookkeeping words (where it starts and how
          # full it is).
          def list_declarations(program)
            declarations = {}
            program.walk do |node|
              next unless node.kind == :list_new

              # ...at the list's own element width, so a byte-wide list is counted as the
              # quarter of the memory it really takes rather than as a word-wide one.
              slot = Build::ELEMENT_BYTES.fetch(node.width || :word)
              declarations[node.name] = [(node.capacity * slot) + (2 * WORD), node]
            end
            declarations
          end

          # The contributor label for a list: a pool backing list (named __pool_<pool>_<field>)
          # reads as its pool; anything else as itself.
          def label_for(list_name)
            text = list_name.to_s
            return "list :#{list_name}" unless text.start_with?("__pool_")

            "pool :#{text.delete_prefix('__pool_').rpartition('_').first}"
          end

          # The kinds that name a variable, and which of their attributes hold the name(s).
          # Every variable that reserves a word is reached by one of these — a read
          # (var_ref), a write (set/add/…), or a loop/timer's hidden counter.
          VARIABLES_OF = {
            set: ->(n) { [n.var] }, add: ->(n) { [n.var] }, sub: ->(n) { [n.var] },
            negate: ->(n) { [n.var] }, abs: ->(n) { [n.var] }, negate_abs: ->(n) { [n.var] },
            clamp: ->(n) { [n.var] }, copy: ->(n) { [n.dest, n.src] },
            var_ref: ->(n) { [n.name] }, repeat: ->(n) { [n.index] },
            every: ->(n) { [n.counter] }, after: ->(n) { [n.counter] }
          }.freeze

          # The distinct variable names the program uses — each is one word of IWRAM.
          def variable_names(program)
            names = {}
            program.walk do |node|
              reader = VARIABLES_OF[node.kind] or next
              reader.call(node).each { |name| names[name] = true }
            end
            names.keys
          end

          # Total bytes for the save-under buffers moving sprites keep (a width x height
          # patch of 16-bit pixels, padded to a whole word), deduped by name.
          def backing_bytes(program)
            sizes = {}
            program.walk do |node|
              next unless node.kind == :backing_buffer

              sizes[node.name] = round_up_word(node.width * node.height * 2)
            end
            sizes.values.sum
          end

          def round_up_word(bytes) = (bytes + 3) & ~3

          def message(total, users)
            "This program reserves about #{human(total)} of memory for its data. But the console has only " \
              "#{human(IWRAM_BYTES)} of #{PlainWords::QUICK_MEMORY} and #{human(EWRAM_BYTES)} of roomier " \
              "memory, and both are full. The biggest users are #{top_users(users)}. To fix this, use a " \
              "smaller capacity for a pool or a list. Or use fewer fields. Or use narrower items " \
              "(`width: :byte`). Then it all fits."
          end

          # The variables and the sprites' save-buffers can only be in the quick memory, so
          # a program whose variables alone are over it cannot be helped by the other one.
          def pinned_message(pinned, users)
            "This program reserves about #{human(pinned)} of the console's #{PlainWords::QUICK_MEMORY} for " \
              "things that can only live there. But the console has only #{human(IWRAM_BYTES)} of it, and " \
              "about #{human(BUDGET_BYTES)} of that is free for your data — the rest holds the call stack " \
              "and the framework's own state. A list or a pool can move to the roomier memory; a variable " \
              "cannot, because a variable is reached by its distance from the start of the quick one. The " \
              "biggest users are #{top_users(users.reject { |u| u[:movable] })}. To fix this, use fewer " \
              "variables. Or keep the same numbers in a list, which can move."
          end

          def top_users(users)
            users.first(TOP_USERS).map { |user| "#{user[:label]} (#{human(user[:bytes])})" }.join(", ")
          end

          # Bytes as a short human size: whole KB where it's exact, one decimal otherwise,
          # and plain bytes under 1KB (so tiny contributors don't all read "0KB").
          def human(bytes)
            return "#{bytes}B" if bytes < 1024

            kb = bytes / 1024.0
            kb == kb.round ? "#{kb.round}KB" : "#{format('%.1f', kb)}KB"
          end

          def pluralize(count, noun) = "#{count} #{noun}#{'s' unless count == 1}"
        end
      end
    end
  end
end
