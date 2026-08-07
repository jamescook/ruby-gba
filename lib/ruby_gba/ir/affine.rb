# frozen_string_literal: true

module RubyGBA
  module IR
    # The numbers behind drawing an object turned, resized, or both.
    #
    # A display that can do this does not turn the picture and stamp it down. It walks
    # the patch of screen the object covers and asks, for each screen pixel, "which
    # pixel of the picture lands here?" — working BACKWARDS through the transform. A
    # pixel whose answer falls outside the picture simply isn't drawn. That is what
    # gives a turned sprite its stepped edge.
    #
    # Because the question is asked backwards, the four numbers that answer it are the
    # INVERSE of the transform the author asked for. Turning is its own inverse at the
    # opposite angle, which is why rotation alone looks symmetric. Size is not: drawing
    # something at twice its size means stepping through the picture at HALF a pixel per
    # screen pixel, so the matrix carries 1/size, not size. That reciprocal is the one
    # piece of real arithmetic here, and it is a division.
    #
    # Everything is whole numbers in ONE_TH-ths — no floating point anywhere — because
    # the console has no floating point and both backends have to land on identical
    # pixels. Every backend that draws a transformed object goes through here, so there
    # is one place where the rounding is decided.
    module Affine
      # What the matrix calls 1.0. The numbers are held in 256ths, which is the
      # precision sprite hardware keeps them at.
      ONE_TH = 256

      # The matrix numbers are signed and 16 bits wide, so this is the largest one there
      # is. A size small enough to need more than this is held here instead — the
      # picture is then drawn so enormously magnified that a few pixels of it fill the
      # whole box either way, and holding beats wrapping round to a negative.
      MAX = 0x7FFF

      # The smallest size that can be asked for. A size of zero has no reciprocal at
      # all, and a negative one is not a size — both are refused where the author writes
      # them, and held here as well so a size the game works out at run time can never
      # divide by zero.
      MIN_SCALE = 1

      module_function

      # sin(+degrees+) in ONE_TH-ths, as a whole number. Both backends turn a picture
      # through this exact table — one reads it here, the other bakes it into the ROM —
      # so they cannot disagree about an angle.
      def sine(degrees)
        (Math.sin(degrees * Math::PI / 180.0) * ONE_TH).round
      end

      # One over +scale+, in ONE_TH-ths, where +scale+ counts in Build::SCALE_ONE-ths.
      # This is the number the matrix is actually built from (see the note above about
      # working backwards). Whole-number division, truncating, because that is what the
      # console's divide gives back.
      def reciprocal(scale)
        scale = MIN_SCALE if scale < MIN_SCALE
        recip = (Build::SCALE_ONE * ONE_TH) / scale
        recip > MAX ? MAX : recip
      end

      # The four numbers that draw a picture turned +degrees+ clockwise and +scale+ times
      # its size: [PA, PB, PC, PD], each in ONE_TH-ths. A screen pixel (dx, dy) away from
      # the center comes from picture pixel ((PA*dx + PB*dy) / ONE_TH, (PC*dx + PD*dy) /
      # ONE_TH) away from the picture's own center.
      def matrix(degrees, scale)
        recip = reciprocal(scale)
        cos = (sine(degrees + 90) * recip) / ONE_TH # cos d is sin(d + 90) — one table serves both
        sin = (sine(degrees) * recip) / ONE_TH
        [cos, sin, -sin, cos]
      end
    end
  end
end
