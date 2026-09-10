# frozen_string_literal: true

module RubyGBA
  module IR
    # ONE CLASS PER KIND OF NODE. Each says what it is and what operands it carries, and
    # gets a real reader for each of them — so asking a pixel for its width is a
    # NoMethodError at the line that asked, not a nil that travels.
    #
    # +operands+ declares the names AND what each one must hold. A tag of :value marks a
    # wrapped operand, which may be a number known while authoring or one the game works
    # out as it runs; every other tag names an author-time literal of a stated type. The
    # names give accessors and the tags are what {Verifier} checks, so the two cannot
    # drift — they are the same declaration.
    #
    # The behaviour every node shares (children, parent, walking, categories) is mixed in
    # from {Node} and names no kind, so nothing here is known to it.
    module Nodes

      class Abs
        include Node
        kind :abs
        category :var
        operands var: :name
      end

      class Add
        include Node
        kind :add
        category :var
        operands var: :name, operand: :value
      end

      class After
        include Node
        kind :after
        category :control
        operands counter: :name, frames: :int
      end

      class Background
        include Node
        kind :background
        category :draw
        operands name: :name, tiles: :list, map: :list, tile_w: :int, tile_h: :int,
                 layer: :name, affine: :flag
      end

      # The per-frame write that turns and resizes an affine background as a whole (see
      # ScrollBackground, its sibling for plain panning). +angle+ is degrees clockwise,
      # +scale+ is in Build::SCALE_ONE-ths (1.0 = drawn size) — the same units a hardware
      # sprite's rotation/scale carry, so both go through the shared {IR::Affine} rules.
      class AffineBackground
        include Node
        kind :affine_background
        category :draw
        operands name: :name, angle: :value, scale: :value, active: :value
      end

      # One cell of a declared background becomes a different tile, while the game runs —
      # a door opening, a pot breaking, a wall a bomb took out. +col+ and +row+ are cell
      # coordinates and may be worked out as the game runs; +tile+ is which of the
      # background's own tiles goes there, settled while the program is written.
      class SetTile
        include Node
        kind :set_tile
        category :draw
        operands name: :name, col: :value, row: :value, tile: :int
      end

      class BackingBuffer
        include Node
        kind :backing_buffer
        category :data
        operands name: :name, width: :int, height: :int
      end

      class Beep
        include Node
        kind :beep
        category :sound
        operands tone: :tone, duty: :option, decay: :option, volume: :int
      end

      class Binop
        include Node
        kind :binop
        category :value
        operands op: :option, lhs: :value, rhs: :value
      end

      class Bitmap
        include Node
        kind :bitmap
        category :data
        operands name: :name, width: :int, height: :int, pixels: :text, transparent: :int,
                 colors: :list
      end

      class Blit
        include Node
        kind :blit
        category :draw
        operands name: :name, x: :value, y: :value
      end

      class BlitPose
        include Node
        kind :blit_pose
        category :draw
        operands poses: :list, index: :value, x: :value, y: :value
      end

      class Call
        include Node
        kind :call
        category :control
        operands target: :name
      end

      class Camera
        include Node
        kind :camera
        category :draw
        operands x: :value, y: :value
      end

      class Case
        include Node
        kind :case
        category :control
        operands var: :name, clauses: :list
      end

      class Chance
        include Node
        kind :chance
        category :value
        operands draw: :value, percent: :int
      end

      class Clamp
        include Node
        kind :clamp
        category :var
        operands var: :name, min: :value, max: :value
      end

      class ClearScreen
        include Node
        kind :clear_screen
        category :draw
        operands color: :color
      end

      class Copy
        include Node
        kind :copy
        category :var
        operands dest: :name, src: :name
      end

      class Data
        include Node
        kind :data
        category :data
        operands name: :name, bytes: :text
      end

      class DataByte
        include Node
        kind :data_byte
        category :value
        operands name: :name, index: :int
      end

      class DefineSound
        include Node
        kind :define_sound
        category :sound
        operands name: :name, frequency: :int, duty: :option, decay: :option, volume: :int
      end

      class DivFix
        include Node
        kind :div_fix
        category :value
        operands lhs: :value, rhs: :value, fraction_bits: :int
      end

      class DmaFillRect
        include Node
        kind :dma_fill_rect
        category :draw
        operands x: :int, y: :int, w: :int, h: :int, color: :color
      end

      class DrawDigit
        include Node
        kind :draw_digit
        category :draw
        operands value: :value, x: :int, y: :int, color: :color, font: :name
      end

      class DrawRectAt
        include Node
        kind :draw_rect_at
        category :draw
        # +usually+ is how many rows this rectangle normally covers — the estimate's business,
        # not the program's, and the same hint DrawColumnAt takes for the same reason. A height
        # the game works out has no size a build can prove, and a rectangle drawn on the screen
        # has a known ceiling to measure it against (see the note on Pricing#stretched_rows), so
        # the author can say rather than let it guess.
        operands x: :value, y: :value, w: :value, h: :value, color: :color, usually: :int
      end

      # One column of a picture, stretched to a height the program works out. The whole of a
      # first-person view is this, done once per strip across the screen.
      #
      # +width+ is how many pixels ACROSS the strip is. A view whose strips are wider than a
      # pixel shows the same picture column at the same height in each of them, so the width
      # belongs here rather than in a loop the caller writes: one walk down the screen fills
      # the whole strip. It is a number settled while building, because a strip's width is a
      # property of the view rather than something a game works out per frame.
      class DrawColumnAt
        include Node
        kind :draw_column_at
        category :draw
        # +usually+ is how many rows this column normally draws — the estimate's, not the
        # program's. A height the game works out has no size a build can prove, and this is the
        # rare case where it has a known ceiling to be measured against (see the note on
        # Pricing#column_rows), so the author can say rather than let it guess.
        operands name: :name, slice: :value, x: :value, top: :value, height: :value,
                 width: :int, usually: :int
      end

      class DrawText
        include Node
        kind :draw_text
        category :draw
        operands text: :text, x: :int, y: :int, color: :color, font: :name
      end

      class Else
        include Node
        kind :else
        category :control
      end

      class EnableSound
        include Node
        kind :enable_sound
        category :sound
      end

      class Every
        include Node
        kind :every
        category :control
        operands counter: :name, period: :int
      end

      class Fade
        include Node
        kind :fade
        category :draw
        operands toward: :option, amount: :value, under: :name
      end

      class FillRect
        include Node
        kind :fill_rect
        category :draw
        operands x: :int, y: :int, w: :int, h: :int, color: :color
      end

      class Func
        include Node
        kind :func
        category :control
        operands name: :name, fast: :flag
      end

      # A part of the picture that everything inside this stays within. Whatever the children
      # draw is cut off at these edges, exactly as it is cut off at the edges of the picture —
      # so the pixels outside are not merely covered up afterwards, they are never worked out.
      #
      # A program that shows one part of the picture over another — a strip of the world with a
      # panel of numbers under it — needs this to say which part is which. Without it the world
      # is drawn over the whole picture and the panel painted on top, and everything under the
      # panel was worked out for nothing.
      #
      # The edges are settled while building. Where the parts of a picture are is a fact about
      # how a program is laid out, not something it works out as it goes.
      class Inside
        include Node
        kind :inside
        category :control
        operands x: :int, y: :int, w: :int, h: :int
      end

      class Halt
        include Node
        kind :halt
        category :control
      end

      class Held
        include Node
        kind :held
        category :value
        operands button: :option
      end

      class If
        include Node
        kind :if
        category :control
        # over/usually/of and runs/per are the estimate's, not the program's. The first three
        # say how many slots of a walk over `of` of them are usually in use, and which set
        # they belong to; runs/per say the body runs on `runs` frames in every `per`. Nothing
        # runs differently either way; see Build#if_.
        operands cond: :value, else: :branch, over: :name, usually: :int, of: :int,
                 runs: :int, per: :int
      end

      class Int
        include Node
        kind :int
        category :value
        operands value: :int
      end

      # The stack of layers a picture is built from, backmost first — and which one of
      # them, if any, you can see through. A stack holds at most one see-through layer,
      # so it is named here rather than being a property of each layer: `transparent` is
      # the layer's name and `transparency` is how much of what is behind it shows, 0
      # (solid) to 100 (invisible).
      #
      # The amount is a value rather than a number, because a picture can go on changing
      # it — fog that thickens, water that gets murkier the deeper you swim. A number
      # settled while authoring is written once and never again; one the program works out
      # is re-read every frame (see SeeThrough).
      class Layers
        include Node
        kind :layers
        category :data
        operands names: :list, transparent: :name, transparency: :value
      end

      # How see-through the see-through layer is, RIGHT NOW.
      #
      # Only a picture whose amount is worked out as it runs carries this: the framework
      # puts one at each frame boundary so the display is told again before the frame is
      # drawn. Which layer it means is on the Layers node — a picture has one.
      class SeeThrough
        include Node
        kind :see_through
        category :draw
        operands amount: :value
      end

      class ListDrop
        include Node
        kind :list_drop
        category :list
        operands name: :name, from: :option
      end

      class ListGet
        include Node
        kind :list_get
        category :value
        operands name: :name, index: :value
      end

      class ListLen
        include Node
        kind :list_len
        category :value
        operands name: :name
      end

      class ListNew
        include Node
        kind :list_new
        category :list
        operands name: :name, capacity: :int, declared: :int, usually: :int, width: :option
      end

      class ListPush
        include Node
        kind :list_push
        category :list
        operands name: :name, value: :value
      end

      class ListSet
        include Node
        kind :list_set
        category :list
        operands name: :name, index: :value, value: :value
      end

      class Loop
        include Node
        kind :loop
        category :control
      end

      class MulFix
        include Node
        kind :mul_fix
        category :value
        operands lhs: :value, rhs: :value, fraction_bits: :int
      end

      class Neg
        include Node
        kind :neg
        category :value
        operands operand: :value
      end

      class Negate
        include Node
        kind :negate
        category :var
        operands var: :name
      end

      class NegateAbs
        include Node
        kind :negate_abs
        category :var
        operands var: :name
      end

      class Noise
        include Node
        kind :noise
        category :sound
        operands preset: :option, pitch: :option, decay: :option, volume: :int, metallic: :flag
      end

      class Object
        include Node
        kind :object
        category :draw
        operands name: :name,
                 poses: :list, pose: :value, x: :value,
                 y: :value, active: :value, angle: :value,
                 scale: :value, layer: :name
      end

      class OnTimer
        include Node
        kind :on_timer
        category :control
        operands timer: :name
      end

      class Pixel
        include Node
        kind :pixel
        category :draw
        operands x: :value, y: :value, color: :color
      end

      class PixelsOverlap
        include Node
        kind :pixels_overlap
        category :value
        operands a_poses: :list,
                 a_pose: :value, a_x: :value, a_y: :value,
                 b_poses: :list, b_pose: :value, b_x: :value,
                 b_y: :value
      end

      class PlaySample
        include Node
        kind :play_sample
        category :sound
        operands name: :name, loop: :flag, volume: :option, pitch: :option
      end

      class PlaySong
        include Node
        kind :play_song
        category :sound
        operands name: :name
      end

      class PresentObjects
        include Node
        kind :present_objects
        category :draw
        operands names: :list
      end

      class Pressed
        include Node
        kind :pressed
        category :value
        operands button: :option
      end

      class Program
        include Node
        kind :program
        category :root
      end

      class Raw
        include Node
        kind :raw
        category :control
        operands bytes: :text
      end

      class ReadScanline
        include Node
        kind :read_scanline
        category :value
      end

      # +stop_when+ is a value checked before each pass: when it is true the loop ends early,
      # which is what a search wants — a ray that has met a wall has its answer and every step
      # after it is spent proving nothing.
      # +usually+ is how many passes a loop that can STOP EARLY normally makes. The count is
      # then a ceiling rather than a number of passes, and nothing in the program says where
      # the loop really leaves — so this is the same hint a list and a pool take, and for the
      # same reason: what the estimate needs is the every-frame load, not the worst moment.
      # nil where nothing was said, or where the loop runs to its count every time.
      class Repeat
        include Node
        kind :repeat
        category :control
        operands count: :value, index: :name, stop_when: :value, usually: :int, most: :int
      end

      class RestoreRegion
        include Node
        kind :restore_region
        category :draw
        operands buffer: :name, x: :value, y: :value
      end

      class Sample
        include Node
        kind :sample
        category :data
        operands name: :name, bytes: :text, rate: :int, note: :option
      end

      class SaveInit
        include Node
        kind :save_init
        category :var
        operands vars: :list, magic: :int
      end

      class SaveRegion
        include Node
        kind :save_region
        category :draw
        operands buffer: :name, x: :value, y: :value
      end

      class SaveStore
        include Node
        kind :save_store
        category :var
        operands var: :name, slot: :int
      end

      class Screen
        include Node
        kind :screen
        category :draw
        operands mode: :mode, buffered: :flag, colors: :list
      end

      class ScrollBackground
        include Node
        kind :scroll_background
        category :draw
        operands name: :name, x: :value, y: :value
      end

      class ScrollRows
        include Node
        kind :scroll_rows
        category :draw
        operands name: :name, row: :name, offset: :value
      end

      class Set
        include Node
        kind :set
        category :var
        operands var: :name, value: :value
      end

      class ShiftRight
        include Node
        kind :shift_right
        category :value
        operands operand: :value, bits: :int
      end

      class Song
        include Node
        kind :song
        category :sound
        operands name: :name, voices: :list, total_frames: :int
      end

      class StopMusic
        include Node
        kind :stop_music
        category :sound
      end

      class StopSample
        include Node
        kind :stop_sample
        category :sound
        operands name: :name
      end

      class StopWave
        include Node
        kind :stop_wave
        category :sound
      end

      class Sub
        include Node
        kind :sub
        category :var
        operands var: :name, operand: :value
      end

      class Table
        include Node
        kind :table
        category :data
        operands name: :name, values: :list, width: :option, signed: :flag
      end

      class TableGet
        include Node
        kind :table_get
        category :value
        operands name: :name, index: :value
      end

      class TimerStart
        include Node
        kind :timer_start
        category :control
        operands name: :name, hz: :int
      end

      class TimerStop
        include Node
        kind :timer_stop
        category :control
        operands name: :name
      end

      class TimerTicks
        include Node
        kind :timer_ticks
        category :value
        operands name: :name
      end

      class Tint
        include Node
        kind :tint
        category :draw
        operands color: :color, amount: :value
      end

      class VarRef
        include Node
        kind :var_ref
        category :value
        operands name: :name
      end

      class WaitVblank
        include Node
        kind :wait_vblank
        category :control
      end

      class Wave
        include Node
        kind :wave
        category :sound
        operands shape: :option, frequency: :int, volume: :option
      end

      # Every kind, by its name. Derived from the classes above rather than kept alongside
      # them, so it cannot fall behind: a class that exists is in here.
      def self.by_kind
        @by_kind ||= constants.map { |name| const_get(name) }.to_h { |type| [type.kind, type] }
      end

      # Build a node of the named kind. The one place a kind SYMBOL becomes a class, for
      # callers that have the name rather than the type.
      def self.build(kind, children: [], source: nil, **operands)
        by_kind.fetch(kind) { raise ArgumentError, "no IR node kind #{kind.inspect}" }
               .new(children: children, source: source, **operands)
      end
    end
  end
end
