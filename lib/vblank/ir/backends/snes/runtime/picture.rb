# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE PICTURE: what the pass drew, copied to the console in the vertical blank after it.
          #
          #   rt_picture_start     at power-on, before the first line of the game
          #   rt_picture_prepare   at the end of every pass, before the wait: what is to be copied,
          #                        worked out while the screen is still being drawn
          #   rt_upload_whole      everything, with the screen off (the first pass, and a game that
          #                        stops before its first frame)
          #   rt_upload            what the pass changed, in the blank
          module Picture
            module_function

            def reserve(_memory) = nil

            def emit(asm, _memory)
              %w[rt_picture_start rt_picture_prepare rt_upload_whole rt_upload].each do |name|
                asm.label(name)
                asm.rtl
              end
            end
          end
        end
      end
    end
  end
end
