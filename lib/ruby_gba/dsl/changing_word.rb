# frozen_string_literal: true

module RubyGBA
  # A WORD THAT CHANGES A VARIABLE ENDS IN `!`, and this is the sentence that says so when one
  # is written without it — on a variable's handle, on a pool field, and as a flat verb.
  #
  # It lives in one place because the wording and the advice under it are one promise to the
  # reader: the same slip should read the same way whichever of the three shapes it was written
  # in. Written twice, the two copies differed in how they named an operand, and one of them
  # answered a variable by describing the whole build.
  module ChangingWord
    module_function

    # +written+ is the call as the author wrote it (`hp.add`, `add :hp, 1`), +bang+ the same with
    # its `!`, +instead+ how to get the same number without changing anything, and +at+ the line
    # they wrote it on.
    def refusal(written:, bang:, instead: "", at: "")
      "`#{written}` does not change a variable. A word that changes a variable ends in `!`. " \
        "To change it, write `#{bang}`.#{instead}#{at}"
    end

    # ...and that advice, for a word whose new-number form is an operator: `hp + 1`. The two
    # sides are named the way the author would write them, and a side with no name to give — an
    # expression worked out on the spot — leaves the advice out rather than describing itself.
    def operator_advice(left, operator, right, handles: false)
      left = spelled(left)
      right = spelled(right)
      return "" if operator.nil? || left.nil? || right.nil?

      tail = handles ? " with the handles that `var` gives you" : ""
      " To get a new number and keep the variable as it is, write `#{left} #{operator} #{right}`#{tail}."
    end

    # An operand as the author would write it: a variable by its own name, a number as itself.
    # Nil for anything else, which has no name to be written by.
    def spelled(operand)
      case operand
      when nil then nil
      when Symbol then operand.to_s
      when Numeric then operand.inspect
      when String then operand
      else operand.name&.to_s if operand.respond_to?(:name)
      end
    end
  end
end
