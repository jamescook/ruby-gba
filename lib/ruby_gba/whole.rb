# frozen_string_literal: true

module RubyGBA
  # WHOLE NUMBERS AN AUTHOR WRITES — a capacity, a rate, a size, how many digits.
  #
  # Fifteen verbs across the surface and the op-tree ask the same thing of an argument
  # before they will accept it, and asking it in fifteen places is how fifteen places come
  # to disagree about what counts. So the question lives here once.
  #
  # It only ANSWERS. Each caller still raises its own error, because each has something
  # different to teach: a pool tells you to use a smaller capacity, a grid tells you a cell
  # size must be even so the fast fill is legal, a timer points you at `every` for slower
  # timing. Folding those into one sentence would save a few lines and cost the thing the
  # guardrails are for.
  module Whole
    module_function

    # A count of something there must be at least one of.
    def positive?(value) = value.is_a?(Integer) && value.positive?

    # A whole number inside a range the caller names — a volume of 0 to 15, a percentage,
    # a list's usual length against its capacity.
    def within?(value, range) = value.is_a?(Integer) && range.cover?(value)
  end
end
