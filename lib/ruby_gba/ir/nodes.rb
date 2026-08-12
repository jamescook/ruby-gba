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
                 layer: :name
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
        operands name: :name, width: :int, height: :int, pixels: :text, transparent: :int
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
        operands x: :value, y: :value, w: :value, h: :value, color: :color
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
        # over/usually/of are the estimate's, not the program's — a test that guards one
        # slot of a walk over `of` of them says how many are usually in use, and which set
        # they belong to. Nothing runs differently; see Build#if_.
        operands cond: :value, else: :branch, over: :name, usually: :int, of: :int
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
      class Layers
        include Node
        kind :layers
        category :data
        operands names: :list, transparent: :name, transparency: :int
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
        operands name: :name, capacity: :int, declared: :int, usually: :int
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

      class Repeat
        include Node
        kind :repeat
        category :control
        operands count: :value, index: :name
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
        operands mode: :mode, buffered: :flag
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
