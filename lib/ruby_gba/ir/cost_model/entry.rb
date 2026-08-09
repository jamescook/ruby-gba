# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # One entry in the cost tree: a piece of the frame's work, what it costs, and whatever
      # is nested inside it. The rollup builds them, the tree pass reshapes them (aggregating
      # identical siblings, grouping by source, pruning by depth) and the report prints them.
      #
      # Only +op+ and +cost+ are always there. The rest describe an entry that has something
      # more to say: a drawn rectangle carries its width and height so two different sizes do
      # not fold together, a container carries the children it sums, a loop carries how many
      # times a frame runs its body, and an entry that stands for a whole section carries the
      # section it belongs to. An entry that has nothing to say about one of those leaves it
      # alone rather than carrying a nil that means nothing. +collapsed+ is put on by the
      # depth pruning: the children are gone and this is how many went.
      Entry = Data.define(:op, :cost, :name, :label, :children, :w, :h,
                          :source, :count, :category, :factor, :collapsed) do
        def initialize(op:, cost: 0, name: nil, label: nil, children: [], w: nil, h: nil,
                       source: nil, count: nil, category: nil, factor: nil, collapsed: nil)
          super
        end

        # What to call this entry when it is printed or counted. The label is what a person
        # reads and the name is what identical entries are grouped under; an entry with
        # neither falls back to the operation itself.
        def title
          label || name || op.to_s
        end

        # How many times a frame runs this, which only a loop container says.
        def passes
          factor || 1
        end
      end
    end
  end
end
