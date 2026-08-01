# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # Every variable, list, and component pool a program declares lives in the GBA's
        # 32KB of fast on-chip RAM. The allocator just hands out the next free address and
        # never looks at the ceiling, so a program that reserves more than fits silently
        # overruns into whatever memory follows — a corrupt, black-screen ROM with nothing
        # to say why. A component pool (capacity x fields words) makes this easy to hit,
        # but it's a general gap: enough variables, or one oversized list, does it too.
        #
        # This sums what the whole program reserves — a word per variable, a list's slots
        # plus its two bookkeeping words, the save-under buffer a moving sprite keeps — and
        # if the total is over the usable budget it stops the build with a plain-language
        # error: how much is needed, how much there is, and the biggest users so the fix is
        # obvious. It's the thorough, whole-program companion to the per-pool capacity
        # ceiling `pool` bakes in: that catches one insane pool, this catches several
        # ordinary allocations adding up.
        class IwramBudget
          NAME = :iwram_budget

          # The GBA's fast RAM is 32KB, but not all of it is free for the program's data:
          # the call stack lives at the top and the framework keeps a little scratch of its
          # own. The usable budget is the total minus a headroom reserve, so staying under
          # it leaves room for both. (A word — a variable or a list slot — is 4 bytes.)
          IWRAM_BYTES = 32 * 1024
          RESERVED_BYTES = 4 * 1024
          BUDGET_BYTES = IWRAM_BYTES - RESERVED_BYTES
          WORD = 4

          # How many top users to name in the error — enough to point at the fix,
          # not so many the message becomes a memory dump.
          TOP_USERS = 3

          def detect(program)
            users = contributors(program)
            total = users.sum { |user| user[:bytes] }
            return [] if total <= BUDGET_BYTES

            [Finding.new(check: NAME, severity: :error, message: message(total, users), fix: nil)]
          end

          private

          # Everything the program reserves IWRAM for, each as { label:, bytes: }, largest
          # first — so the message can name the total and point at the biggest users.
          def contributors(program)
            items = list_and_pool_items(program)

            var_count = variable_names(program).size
            items << { label: pluralize(var_count, "variable"), bytes: var_count * WORD } if var_count.positive?

            buffers = backing_bytes(program)
            items << { label: "sprite save-buffers", bytes: buffers } if buffers.positive?

            items.sort_by { |item| -item[:bytes] }
          end

          # Lists as contributors — but a pool's several backing lists collapse into one
          # "pool :name" (the author declared one pool, not five lists), while a standalone
          # list stays "list :name".
          def list_and_pool_items(program)
            grouped = Hash.new(0)
            list_bytes(program).each { |name, bytes| grouped[label_for(name)] += bytes }
            grouped.map { |label, bytes| { label: label, bytes: bytes } }
          end

          # name => bytes for every list the program creates (deduped by name — a list
          # re-declared to reset it reserves its storage once). A list is its `capacity`
          # slots plus two hidden bookkeeping words (where it starts and how full it is).
          def list_bytes(program)
            bytes = {}
            program.walk do |node|
              next unless node.kind == :list_new

              bytes[node[:name]] = (node[:capacity] + 2) * WORD
            end
            bytes
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
          VAR_NAME_ATTRS = {
            set: %i[var], add: %i[var], sub: %i[var], negate: %i[var], abs: %i[var],
            negate_abs: %i[var], clamp: %i[var], copy: %i[dest src], var_ref: %i[name],
            repeat: %i[index], every: %i[counter], after: %i[counter]
          }.freeze

          # The distinct variable names the program uses — each is one word of IWRAM.
          def variable_names(program)
            names = {}
            program.walk do |node|
              (VAR_NAME_ATTRS[node.kind] || []).each { |attr| names[node[attr]] = true }
            end
            names.keys
          end

          # Total bytes for the save-under buffers moving sprites keep (a width x height
          # patch of 16-bit pixels, padded to a whole word), deduped by name.
          def backing_bytes(program)
            sizes = {}
            program.walk do |node|
              next unless node.kind == :backing_buffer

              sizes[node[:name]] = round_up_word(node[:width] * node[:height] * 2)
            end
            sizes.values.sum
          end

          def round_up_word(bytes) = (bytes + 3) & ~3

          def message(total, users)
            top = users.first(TOP_USERS).map { |user| "#{user[:label]} (#{human(user[:bytes])})" }.join(", ")
            "This program reserves about #{human(total)} of fast RAM. But the GBA has only #{human(IWRAM_BYTES)} " \
              "of fast RAM in total. Only about #{human(BUDGET_BYTES)} of that is free for your data. The rest " \
              "holds the call stack and the framework's own state. The biggest users are #{top}. To fix this, " \
              "use a smaller capacity for a pool or a list. Or use fewer fields. Or use one large list in place " \
              "of several. Then it all fits."
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
