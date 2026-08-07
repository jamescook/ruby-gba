# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Shaping the cost tree into something a person can read. Data in, data out — no
      # printing here, which is why these are asserted directly rather than through the
      # rendered text.
      #
      # {Rollup} produces one node per op, and a real game produces a great many of them:
      # a draw_number is ten glyphs, a brick grid is the same five-op block over and over,
      # a game split across files interleaves work from all of them. Read raw, that is a
      # wall. So the tree gets folded three ways — a run of the same op into "op ×N", a
      # repeated BLOCK of ops into one group shown once, and consecutive siblings into
      # per-file subtotals — then grouped into drawing / sound / logic sections and pruned
      # to a depth.
      #
      # The folding happens at render time, on a copy. #category_tree stays raw so
      # #as_json and the tests that read it see the real structure.
      module Tree
        # Fold runs of identical sibling leaves (same op + size) into one "op ×N" node,
        # recursing into children. Tames verbose fan-outs (draw_number's 10 glyphs, a
        # row of identical cells) without losing the rolled-up cost.
        def aggregate(nodes)
          nodes.each_with_object([]) do |raw, out|
            node = raw[:children].to_a.empty? ? raw.dup : raw.merge(children: aggregate(raw[:children]))
            prev = out.last
            if node[:children].to_a.empty? && prev && prev[:children].to_a.empty? &&
               prev[:op] == node[:op] && prev[:w] == node[:w] && prev[:h] == node[:h]
              out[-1] = prev.merge(count: (prev[:count] || 1) + 1, cost: prev[:cost] + node[:cost],
                                   label: "#{name_of(node)} ×#{(prev[:count] || 1) + 1}")
            else
              out << node
            end
          end
        end

        # Fold runs of an identical repeated *block* of siblings into one group shown
        # once, with a "×N". Where #aggregate tames a run of the same single op (10
        # glyphs), this tames a repeated multi-op pattern — the wall of identical
        # "set, add, sub, negate, beep" groups an unrolled per-thing check (a brick
        # grid's collision) turns into. The group carries the whole run's rolled-up
        # cost; its children show the block once. Recurses into children first.
        def collapse_repeats(nodes)
          folded = nodes.map do |node|
            node[:children].to_a.empty? ? node : node.merge(children: collapse_repeats(node[:children]))
          end

          out = []
          i = 0
          while i < folded.length
            period, count = longest_repeat(folded, i)
            if count >= 2
              run = folded[i, period * count]
              out << { op: :group, label: "(repeated ×#{count})",
                       cost: run.sum { |node| node[:cost] }, count: count, children: folded[i, period] }
              i += period * count
            else
              out << folded[i]
              i += 1
            end
          end
          out
        end

        # Bucket consecutive sibling nodes by the source FILE they came from, so a game
        # split across collaborator files (player.rb, enemies.rb, hud.rb — each a plain
        # object handed the builder) shows each file's per-frame work as its own labeled
        # subtotal instead of one flat list. No author effort: every node already carries
        # its DSL call site, so organizing code into files is the only step and the
        # breakdown follows. Recurses into children first, and only groups where the
        # siblings actually come from two or more files — there's nothing to separate in a
        # single-file scene, so it's left untouched. Order is preserved (like
        # #collapse_repeats), and a lone node from a file isn't wrapped in a group of one.
        def group_by_source(nodes)
          folded = nodes.map do |node|
            node[:children].to_a.empty? ? node : node.merge(children: group_by_source(node[:children]))
          end
          return folded if folded.map { |node| source_file(node) }.compact.uniq.length < 2

          out = []
          i = 0
          while i < folded.length
            file = source_file(folded[i])
            unless file
              out << folded[i]
              i += 1
              next
            end
            j = i
            j += 1 while j < folded.length && source_file(folded[j]) == file
            run = folded[i...j]
            out << (run.length > 1 ? { op: :group, label: file, cost: run.sum { |n| n[:cost] }, children: run } : run.first)
            i = j
          end
          out
        end

        # The source file a cost node came from — the basename of its DSL call site
        # ("player.rb" from "player.rb:42"), or nil for a node with no recorded site.
        def source_file(node)
          site = node[:source]
          site && site.split(":").first
        end

        # Which section an op belongs to: drawing, sound, or logic (the fallback).
        def category_of(op)
          return :drawing if DRAW_KINDS.include?(op)
          return :sound if SOUND_KINDS.include?(op)

          :logic
        end

        # The section a cost-tree node belongs to: a leaf by its op (or an explicit
        # :category a synthetic node declares), a container by where most of its cost
        # lives — a repeat that's mostly drawing counts as drawing.
        def node_category(node)
          return node[:category] if node[:category]
          return category_of(node[:op]) if node[:children].to_a.empty?

          category_totals(node).max_by { |_cat, cost| cost }&.first || :logic
        end

        # Sum a subtree's leaf costs by section — used to place a container in the
        # section holding most of its work.
        def category_totals(node, sums = Hash.new(0))
          if node[:children].to_a.empty?
            sums[node[:category] || category_of(node[:op])] += node[:cost]
          else
            node[:children].each { |child| category_totals(child, sums) }
          end
          sums
        end

        # Group a frame's cost nodes into drawing / sound / logic sections, each a
        # rolled-up subtotal, in that fixed order. The software mixer's per-frame cost
        # joins the sound section as a leaf — it's real recurring work, just not an IR op
        # — so it stops being a bolt-on and rolls up with everything else. Within a
        # section the per-file / repeat folding still applies.
        def group_by_category(nodes, program)
          nodes += mixer_nodes(program)
          buckets = nodes.group_by { |node| node_category(node) }
          CATEGORY_ORDER.filter_map do |cat|
            kids = buckets[cat]
            next if kids.nil? || kids.empty?

            { op: :category, category: cat, label: cat.to_s, cost: kids.sum { |node| node[:cost] },
              children: group_by_source(kids) }
          end
        end

        # The mixer as a cost leaf for the sound section, or none when the program plays
        # no sampled sound. (Its cost model lives in #mixer_verdict.)
        def mixer_nodes(program)
          v = mixer_verdict(program)
          return [] unless v

          [{ op: :mixer, category: :sound, cost: v[:cost], children: [],
             label: "software mixer — worst case, all #{v[:voices]} voices summed each frame" }]
        end

        # The frame's cost as drawing / sound / logic sections — the categorized tree the
        # report renders and #as_json serializes. Left raw (per-file grouping only); the
        # display folding (aggregate/collapse for readability) happens at render time, so
        # it can't erase the structure #as_json and its tests read.
        def category_tree(program, focus: nil)
          group_by_category(analyze(program, focus: focus), program)
        end

        # Starting at +i+, the adjacent block-repeat that folds the most nodes: the
        # [period, count] maximizing period*count with at least two repeats (so the
        # smallest repeating unit wins a tie). [1, 1] means nothing repeats.
        def longest_repeat(nodes, i)
          best = [1, 1]
          ((nodes.length - i) / 2).downto(2) do |period|
            count = repeat_run(nodes, i, period)
            best = [period, count] if count >= 2 && (period * count) >= (best[0] * best[1])
          end
          best
        end

        # How many times the +period+-long block at +i+ repeats back to back.
        def repeat_run(nodes, i, period)
          first = nodes[i, period].map { |node| signature(node) }
          count = 1
          j = i + period
          while j + period <= nodes.length && nodes[j, period].map { |node| signature(node) } == first
            count += 1
            j += period
          end
          count
        end

        # A structural fingerprint: two nodes match when their op, label, size, and
        # children all match — so only truly identical blocks fold together.
        def signature(node)
          [node[:op], node[:label], node[:w], node[:h], node[:children].to_a.map { |child| signature(child) }]
        end

        # Collapse subtrees deeper than +max_depth+ into a leaf that remembers how many
        # ops it hid — the depth limit that keeps a big program's tree readable.
        def prune(nodes, max_depth, depth = 0)
          nodes.map do |node|
            kids = node[:children].to_a
            if kids.any? && depth >= max_depth
              node.merge(children: [], collapsed: leaf_count(node))
            elsif kids.any?
              node.merge(children: prune(kids, max_depth, depth + 1))
            else
              node
            end
          end
        end

        # The +top+ hottest op kinds across the whole tree — the flat "profiler" view.
        #
        # A leaf is counted once for every time a frame runs it, so an op inside a loop
        # weighs what it really costs the frame. That is the only way this view means
        # anything: a program's hot work is nearly always inside a loop, and counting a
        # body once put the raycaster's 30 wall divides on the list at a thirtieth of
        # what they cost. The weights come from the same numbers the tree rolls up with,
        # so these add up to the frame — see #weigh_leaves.
        def hot_ops(nodes, top = 5)
          weigh_leaves(nodes).group_by { |leaf, _times| leaf[:op] }
                             .map { |op, rows| hot_row(op, rows) }
                             .sort_by { |h| -h[:cost] }.first(top)
        end

        # One line of the hottest list, from every [leaf, times] pair sharing an op kind.
        def hot_row(op, rows)
          first, = rows.first
          { op: op, name: name_of(first),
            cost: rows.sum { |leaf, times| leaf[:cost] * times },
            count: rows.sum { |leaf, times| (leaf[:count] || 1) * times } }
        end

        # Every leaf in the tree paired with how many times a frame reaches it: the loop
        # counts above it, multiplied. A scene branch the estimate doesn't charge for
        # (only one scene runs a frame, and the cost is the heaviest) weighs nothing.
        def weigh_leaves(nodes, times = 1)
          nodes.flat_map do |node|
            kids = node[:children].to_a
            kids.empty? ? [[node, times]] : weigh_leaves(kids, times * (node[:factor] || 1))
          end
        end

        # What one KIND of op is called, with none of the detail that tells two of them
        # apart — the wording for a fold ("pixel ×10") or a hottest-list line. Most ops
        # are named by their kind; the ones whose kind is machinery rather than English
        # (a divide, a branch test) carry their own name, set where the leaf is made.
        def name_of(node)
          node[:name] || node[:op]
        end

        private

        def leaf_count(node)
          node[:children].to_a.empty? ? 1 : node[:children].sum { |child| leaf_count(child) }
        end

        # A rect's size for the tree. A side the game works out as it runs shows as "?"
        # rather than a number, so a reader can see which rect the estimate had to
        # leave out.
        def size_of(node)
          [node[:w], node[:h]].map { |side| const_side(side) || "?" }.join("x")
        end

        # How a frame's sprites read in the tree. Just a count while they only move; once
        # some of them turn or change size the count alone hides where the cost went, so
        # those are called out — a sprite that resizes costs about three times one that
        # only moves, and the reader has no other way to see that from a single line.
        def sprite_tally(names)
          sprites = names.filter_map { |name| @objects && @objects[name] }
          turning = sprites.count { |sprite| sprite.turns && !sprite.resizes }
          resizing = sprites.count(&:resizes)
          parts = ["#{names.length} sprite#{'s' unless names.length == 1}"]
          parts << "#{turning} turning" if turning.positive?
          parts << "#{resizing} resizing" if resizing.positive?
          parts.join(", ")
        end

        # How one op reads in the tree — its kind plus whatever detail tells two of them
        # apart at a glance (which image a blit draws, how big a rect is).
        def label_of(node)
          case node.kind
          when :fill_rect, :dma_fill_rect, :draw_rect_at then "#{node.kind} #{size_of(node)}"
          when :draw_text then "draw_text #{node[:text].inspect}"
          when :draw_digit then "draw_digit"
          when :blit then "blit :#{node[:name]}"
          when :blit_pose then "blit_pose (#{node[:poses].length} poses)"
          when :save_region then "save_region :#{node[:buffer]}"
          when :restore_region then "restore_region :#{node[:buffer]}"
          when :present_objects then "present_objects (#{sprite_tally(node[:names].to_a)})"
          when :scroll_background then "scroll_background :#{node[:name]}"
          when :background then "background :#{node[:name]}"
          when :play_song then "play_song :#{node[:name]} (#{song_notes(node[:name])} notes)"
          when :beep then "beep #{node[:tone].inspect}"
          else node.kind.to_s
          end
        end
      end
    end
  end
end
