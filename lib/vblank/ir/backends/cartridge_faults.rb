# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHAT WENT WRONG IN A CARTRIDGE THAT STOPPED, by number: one table for every console whose
      # runtime keeps the number where a reader can find it (GBC::Runtime::Frame and
      # SNES::Runtime::Frame take these in). The runtime writes the number as it stops the game, and
      # the reader of the running cartridge turns it back into the interpreter's words
      # (CartridgeHeadlessRun#fault_message). One table, so a number means the same on every console
      # and the words are written once. Where each runtime keeps the number, and the two numbers
      # beside it that say how, is that runtime's own.
      #
      # A console whose runtime never stops for one of these never writes its number: the Super
      # Nintendo's copies no list, and the Color's has no queue of cells to fill.
      module CartridgeFaults
        INDEX_OUT_OF_RANGE = 1
        LIST_FULL = 2
        LIST_EMPTY = 3 # the first number: nought for the back, anything else the front
        COPY_TOO_LONG = 4
        COPY_PAST_TABLE = 5
        PICTURE_NOT_THERE = 6 # a sprite showing a picture its list does not have: the pose, the count
        SAVE_READ_OUTSIDE = 7
        SAVE_WRITE_OUTSIDE = 8
        PICTURE_NOT_UP = 9 # the numbers: which check stopped it (GBC::Places#picture_checks), and the pose
        GROUPS_NOT_TOGETHER = 10 # the number: which set of picture groups (GBC::Places#together_checks)
        CELLS_FULL = 11 # more cells of a background changed in one pass than the queue for the blank holds
      end
    end
  end
end
