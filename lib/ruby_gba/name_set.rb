# frozen_string_literal: true

module RubyGBA
  # THE NAMES ONE PLACE CAN HOLD, and the number each of them turns out to be.
  #
  # A game's states are names — :idle, :chase, :attack; :title, :playing, :over — and what
  # keeps them is a variable, which holds a number. Written out, that means the author picks a
  # number per state, writes the names next to the numbers in a comment, and keeps any list of
  # routines in that same order by hand. Every one of those three is somewhere the two can
  # drift apart, and none of it is what the game is about.
  #
  # So the author writes names and this gives each one a number, in the order it first appears.
  # It is the bargain the framework already makes for colours: they are named where a program
  # is written, and the console is handed a number out of a table it never sees.
  #
  # A name is added the first time it is used, wherever that is — declared, assigned, compared
  # against. So the set is only complete once the whole program has been built, which is why
  # anything that needs all of them (a call that picks a routine by the name a variable holds)
  # asks at the end rather than where it was written.
  class NameSet
    # @param holder [String] what keeps these names, for a message ("the variable :mode")
    def initialize(holder)
      @holder = holder
      @names = []
    end

    # The names it can hold, in number order.
    def names = @names.dup

    # The number for +name+, giving it one if this is the first time it has been seen.
    def number_for(name)
      @names << name unless @names.include?(name)
      @names.index(name)
    end

    # What holds these names, for a message.
    attr_reader :holder

    def empty? = @names.empty?
  end
end
