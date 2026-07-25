# frozen_string_literal: true

module RubyGBA
  class Builder
    # Debug/test-only build verbs — deliberately NOT part of the public game DSL and
    # NOT mixed into Builder by default. A game developer never sees these; a test or
    # a measurement harness opts in with `builder.extend(Builder::Debug)`.
    #
    # The point is that even our own probing goes through the IR, not around it:
    # these verbs build ordinary IR nodes (a value here, plain variable ops there) so
    # a debug program is still inspectable, still lowered by the real backend, and
    # still consistent across backends where it can be — rather than shipping raw
    # assembly down the pipe. The one genuinely hardware-only bit, reading the live
    # scanline, is a first-class node (read_scanline) the backend owns, not a blob.
    module Debug
      Build = IR::Build

      # The scanline the console is drawing right now (VCOUNT, 0..227), as a {Value}
      # you can do arithmetic on. It's how a probe measures how far into a frame the
      # drawing has reached — sample it right after drawing, and how far past the
      # start of the vertical blank (scanline 160) it is says how much of the safe
      # window the frame used. Hardware-only: the headless interpreter refuses it.
      def read_scanline
        Value.new(self, Build.read_scanline)
      end
    end
  end
end
