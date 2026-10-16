# frozen_string_literal: true

module RubyGBA
  module IR
    # A program that did something no backend allows while it ran: pushed onto a full list,
    # played a recording nobody declared, spent a frame that never ends. Every backend that
    # plays a program raises this one error for it, carrying its own sentence about what
    # happened, so a game's test asserts one thing whichever backend played the game.
    #
    # It is the GAME going wrong, and only that. A backend failing in its own right — a
    # compiler that is missing, a program that crashed — raises an error of that backend's.
    class ProgramError < StandardError; end
  end
end
