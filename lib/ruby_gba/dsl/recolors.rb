# frozen_string_literal: true

module RubyGBA
  # THE OTHER COLOURS ONE SPRITE CAN BE DRAWN WITH, and the writes that pick between them.
  #
  # A sprite and a pool both have this, and they differ only in where the choice is kept:
  # a variable of the sprite's own, or a slot per instance, read by one object each. So
  # the owner hands in the place to write and this works out what to write there.
  #
  # The objects count the lists from 0 in the order they were first named here, and any
  # other number means the sprite's own colours. A set of lists named together — the four
  # steps of a pulse — is kept side by side, so picking one of them by a number the game
  # works out is that number plus where the set starts, rather than a test per list.
  class Recolors
    # What `draw_with` is told for a sprite's own colours.
    OWN = :own

    def initialize(builder, subject:, poses:)
      @builder = builder
      @subject = subject # what the sprite is called in an error
      @poses = poses
      @names = []
      @lists = []   # the colours of each of those, checked against the sprite as it was named
      @objects = []
    end

    # An object that is drawn with these lists from now on.
    def reads(node)
      @objects << node
      node.recolors = @lists
      self
    end

    # Record the write that makes +choice+ (anything with a +set!+) name what +which+ says:
    # one list, one of a set picked by +showing+, or the sprite's own colours.
    def draw_with(choice, which, showing)
      names = group(which, showing)
      return choice.set!(IR::Build::NO_RECOLOR) if names.nil?

      start = place(names)
      return choice.set!(start) if showing.nil?

      pick(choice, count: names.length, start: start, showing: showing)
    end

    private

    # Which lists a call named, checked before anything is written. nil is the own colours.
    def group(which, showing)
      if which == OWN
        return nil if showing.nil?

        raise ArgumentError,
              "#{@subject} was told draw_with :#{OWN} and showing:. showing: picks one of several lists, " \
              "and :#{OWN} is not a list. Leave out showing:."
      end
      return [which] if which.is_a?(Symbol) && showing.nil?

      if which.is_a?(Symbol)
        raise ArgumentError,
              "#{@subject} was told draw_with :#{which} and showing:, but that names one list. " \
              "showing: picks between several, so give it a list: draw_with [:#{which}, :other], showing: ..."
      end
      unless which.is_a?(Array) && !which.empty? && which.all?(Symbol)
        raise ArgumentError,
              "#{@subject} was told to draw_with #{which.inspect}. draw_with needs the name of a list of " \
              "colors, a list of those names, or :#{OWN}."
      end
      return which unless showing.nil?

      raise ArgumentError,
            "#{@subject} was told to draw_with #{which.length} lists of colors and nothing to pick " \
            "between them. Say which one with showing:, like draw_with [:#{which.first}, ...], showing: step."
    end

    # Where +names+ sit side by side among the lists, adding them at the end when they do not.
    def place(names)
      found = (0..(@names.length - names.length)).find { |at| @names[at, names.length] == names }
      return found if found

      at = @names.length
      @lists += @builder.colors_to_draw_with(names, poses: @poses, subject: @subject)
      @names.concat(names)
      @objects.each { |node| node.recolors = @lists }
      at
    end

    # One of a set of +count+ lists starting at +start+, picked by +showing+. A number
    # outside the set is the sprite's own colours, which is what a value that has run off
    # the end should look like.
    def pick(choice, count:, start:, showing:)
      fixed = Value.fixed_number(showing)
      return choice.set!(fixed.between?(0, count - 1) ? start + fixed : IR::Build::NO_RECOLOR) if fixed

      step = showing.is_a?(Symbol) ? Value.new(@builder, IR::Build.var_ref(showing), name: showing) : showing
      unless step.respond_to?(:>=) && !step.is_a?(Condition)
        raise ArgumentError,
              "#{@subject} was told to draw_with a list picked by showing: #{step.class}. showing: needs a " \
              "number, counting from 0, like showing: step."
      end
      ((step >= 0) & (step < count)).then { choice.set!(step + start) }.else { choice.set!(IR::Build::NO_RECOLOR) }
    end
  end
end
