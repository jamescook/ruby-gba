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

      # A grid of tiles. +map+ is the grid showing when the program starts. +maps+ is every
      # grid this background can be handed (the first of them being +map+), for a background
      # declared with several — a room per map, a floor per map — and empty for one declared
      # with a single map, which can never change. See ShowMap.
      #
      # +scene+ is the game state this belongs to, where it was declared inside one, and
      # nil for scenery every screen shows. It carries the same fact an Object's +scene+
      # does and for the same reason: a target with a finite number of places to put a
      # layer needs to know which layers are wanted AT THE SAME TIME, and two scenes that
      # take turns never are. See IR::Stacking#screenfuls.
      #
      # +palettes+ is every list of colours this background's tiles were drawn from, each once,
      # and +recolors+ the other ways they can be drawn, in the order BackgroundColors counts
      # them: each one a list for every entry of +palettes+, at the same place, which that
      # list's tiles are then drawn from instead. Both are empty for a background only ever
      # drawn in its own colours. A tile keeps its own places whichever list it reads, the
      # way Object's operand of the same name works for one picture.
      #
      # +choice+ names the variables that say which of +maps+ is showing, empty where there is
      # only one. A background that belongs to a scene is put up as declared each time that
      # scene takes over, so every one of them goes back to 0, the first map, at that moment:
      # left alone they would name the map chosen on the last visit while the cells hold the
      # first, and choosing that map again would be taken as already done.
      class Background
        include Node
        kind :background
        category :draw
        operands name: :name, tiles: :list, map: :list, maps: :list, choice: :list, tile_w: :int,
                 tile_h: :int, layer: :name, scene: :name, affine: :flag, recolors: :list, palettes: :list
      end

      # A background's tiles all draw from a different list of colours — the whole layer at
      # once, where an Object's +recolor+ says it about one picture. +which+ counts from 0
      # through the lists the background was given, and may be worked out as the program
      # runs; a number naming none of them is the background's own colours.
      #
      # Every pixel keeps the place it was drawn at and only the colour that place shows
      # changes, which is what lets one set of tiles be a dozen times of day.
      class BackgroundColors
        include Node
        kind :background_colors
        category :draw
        operands name: :name, which: :value
      end

      # A background's cells all become one of its other maps — a whole room at once, where
      # SetTile changes one cell. +which+ counts from 0 through the maps the background was
      # declared with, and may be worked out as the program runs. The cells become the map
      # exactly as it was declared, so anything SetTile had changed in them is gone.
      class ShowMap
        include Node
        kind :show_map
        category :draw
        operands name: :name, which: :value
      end

      # A RUN OF TILES WHOSE PIXELS COME FROM A LIST THE GAME OWNS, rather than from a
      # picture fixed while the program is built. +tiles+ names them in order — a background's
      # map names them like any other tile — and +list+ is where their pixels are kept: tile k
      # is the 32 bytes from k × 32, each byte two pixels, the left one in the low four bits,
      # each of those a place in +colors+ (place 0 is see-through). The tiles start
      # see-through and show what the list holds only after a CopyTiles.
      #
      # A run can instead be ONE PICTURE a sprite shows: +picture+ names it, +width+ and
      # +height+ are its size in pixels, and its tiles are the list's 32-byte runs taken left
      # to right and then top to bottom — the order a sprite's tiles are kept in. +tiles+ is
      # empty for one of those, and +picture+ nil for a run a background shows.
      class TileRun
        include Node
        kind :tile_run
        declaration!
        category :data
        operands name: :name, list: :name, tiles: :list, colors: :list, picture: :name, width: :int,
                 height: :int
      end

      # Show a TileRun's list on its tiles: every tile of the run takes the pixels its bytes
      # of the list hold now. Where a program is paced by frames this sits in the gap between
      # them, so a picture is never seen half copied.
      class CopyTiles
        include Node
        kind :copy_tiles
        category :draw
        operands name: :name
      end

      # The per-frame write that turns and resizes an affine background as a whole (see
      # ScrollBackground, its sibling for plain panning). +angle+ is degrees clockwise,
      # +scale+ is in Build::SCALE_ONE-ths (1.0 = drawn size) — the same units a hardware
      # sprite's rotation/scale carry, so both go through the shared {IR::Affine} rules.
      #
      # +around_x+/+around_y+ are the point the picture turns around, in screen pixels —
      # the one place that stays still while the rest swings or grows about it, and the
      # place the same point of the picture keeps landing on. The middle of the screen
      # unless the program says otherwise. They are settled while the program is written
      # rather than worked out as it runs, so they are plain numbers on the statement.
      class AffineBackground
        include Node
        kind :affine_background
        category :draw
        operands name: :name, angle: :value, scale: :value,
                 around_x: :int, around_y: :int
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
        declaration!
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

      # Every bit of a number turned the other way — a 1 where there was a 0 and a 0
      # where there was a 1. Its own kind rather than an operator because it takes one
      # operand, exactly as +neg+ does.
      class BitNot
        include Node
        kind :bit_not
        category :value
        operands operand: :value
      end

      # How far a number is from nought: the number, or the number the other way round when
      # it is below nought. A new number — the +abs+ statement changes a variable instead.
      class Absolute
        include Node
        kind :absolute
        category :value
        operands operand: :value
      end

      # A number held inside a range: +min+ when it is below it, +max+ when it is above it,
      # and itself in between. A new number — the +clamp+ statement changes a variable instead.
      class Clamped
        include Node
        kind :clamped
        category :value
        operands operand: :value, min: :value, max: :value
      end

      class Bitmap
        include Node
        kind :bitmap
        declaration!
        category :data
        operands name: :name, width: :int, height: :int, pixels: :text, transparent: :int,
                 colors: :list, places: :text
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

        def callees = [target]
      end

      # Call ONE of +targets+, picked by +which+ — a number counting from 0 through the list,
      # which may be worked out as the program runs. A number naming no routine in the list,
      # below 0 or past its end, calls nothing.
      #
      # Case's sibling, and the difference is what each costs. A case asks its values one at a
      # time, so a long one is a long run of questions; this goes straight to the routine the
      # number names, however many there are. That is what stepping a script wants: one of a
      # hundred and more handlers, picked by an instruction's number, several times a frame.
      class CallOneOf
        include Node
        kind :call_one_of
        category :control
        operands targets: :list, which: :value

        def callees = targets
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

        def callees = clauses.map(&:last)
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
        declaration!
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
        declaration!
        category :sound
        operands name: :name, frequency: :int, duty: :option, decay: :option, volume: :int

        # The sound this declares, as every backend plays it.
        def effect = RubyGBA::Audio::Sound::Effect.new(frequency: frequency, duty: duty, decay: decay, volume: volume)
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

      # Words at a fixed place. +picked+ is a second colour and +showing+ the test that picks
      # it — the words are drawn in +picked+ while the test holds and in +color+ when it does
      # not. The words are ONE set however many colours they can be, so a backend paints them
      # once with the colour worked out first. Without +picked+, +showing+ is never read.
      class DrawText
        include Node
        kind :draw_text
        category :draw
        operands text: :text, x: :int, y: :int, color: :color, font: :name, picked: :color, showing: :value

        def drawn_colors = [color, picked].compact
      end

      class Else
        include Node
        kind :else
        part!
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
        operands toward: :option, amount: :value, under: :name, fraction_bits: :int
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
        declaration!
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

      # The stack of layers a picture is built from, backmost first — and which of them
      # you can see through (+see_through+, a list of SeeThroughLayer). A screen shows at
      # most one of those at a time, so a game has one for each screen that wants one.
      class Layers
        include Node
        kind :layers
        declaration!
        category :data
        operands names: :list, see_through: :list
      end

      # One layer you can see through, and by how much: +shows+ is how much of the layer
      # itself shows and +behind+ how much of what is behind it, each 0 to 100. They need
      # not add to 100 — past it the mix is brighter than either side and stops at full
      # brightness, which is how a glow or a shaft of light looks.
      #
      # +split+ marks the one-number form, where the author said how much of what is
      # behind shows and the layer takes the rest. The two forms round differently, so
      # it is carried rather than inferred: the rest is what is LEFT of a whole once the
      # far side is counted, where two amounts are each taken to the nearest step.
      #
      # The amounts are values rather than numbers, because a picture can go on changing
      # them — fog that thickens, water that gets murkier the deeper you swim. A number
      # settled while authoring is written once and never again; one the program works out
      # is read again every frame (see SeeThrough).
      class SeeThroughLayer
        include Node
        kind :see_through_layer
        declaration!
        category :data
        operands name: :name, shows: :value, behind: :value, split: :flag
      end

      # How see-through +layer+ is, RIGHT NOW.
      #
      # The framework puts one at each frame boundary for a layer whose amounts are worked
      # out as the game runs, so the display is told again before the frame is drawn — and
      # for every see-through layer in a game with more than one, since which of them is
      # on screen changes as the screens take turns. The amounts are on the layer's own
      # SeeThroughLayer.
      class SeeThrough
        include Node
        kind :see_through
        category :draw
        operands layer: :name
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
        # +fast+ is what the author said about where this should live, on a machine with
        # more than one work memory: false for "I know this is cold — give it room", true
        # to insist on the quick one, absent to let the framework decide. It is the same
        # word a routine takes for the same question, and it changes nothing a program
        # does — only how long a read takes.
        operands name: :name, capacity: :int, declared: :int, usually: :int, width: :option,
                 fast: :flag
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

      # Every item from +from+ for +count+ items set to +value+, as that many list_sets would
      # — a count of 0 or less sets none. One statement, so a backend can write a long run a
      # word at a time rather than an item at a time.
      class ListFill
        include Node
        kind :list_fill
        category :list
        operands name: :name, from: :value, count: :value, value: :value
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
        declaration!
        category :draw
        # +scene+ is the game state this thing belongs to, where it was declared inside
        # one. It is on screen only while that state is active, which the +active+
        # operand already carries — what the NAME adds is that a target with somewhere
        # finite to keep pictures knows which of them are needed at the same time.
        #
        # +recolors+ is every other list of colours it can be drawn with, and +recolor+ says
        # which of them it is drawn with now, counting from 0; any other number draws it in
        # its own. A pixel keeps its place in the picture's own list, so drawn with another
        # list it shows whatever colour that list holds at the same place.
        # +name+ is this thing's own identity, handed out as the program is built, and
        # +declared+ is what the AUTHOR called it. They differ because one author's name can
        # stand for many of these — every slot of a pool is one — and because some are drawn
        # for things the author named no sprite for at all, a letter of text among them, which
        # have no +declared+ to give. Keeping it is what lets a target report on what it drew
        # in the author's own words rather than in numbers it made up.
        operands name: :name, declared: :name,
                 poses: :list, pose: :value, x: :value,
                 y: :value, active: :value, angle: :value,
                 scale: :value, layer: :name, scene: :name,
                 recolor: :value, recolors: :list
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

      # A FONT THE PROGRAM DECLARED, the same way a declared picture is a node: it draws
      # nothing itself, it is there to be named by something that draws. `font :heavy do
      # ... end` puts one of these in the tree and `draw_text ..., font: :heavy` names it.
      #
      # It belongs to the program for the reason a picture does — it is part of the game.
      # Kept in one table shared by the whole process instead, the second game built in a
      # session could draw with the first one's font, a name declared twice replaced
      # quietly, and a game building on another core could not declare one at all. The two
      # fonts the framework ships are not in here; those are everybody's, and live in
      # Graphics::Fonts.
      class Font
        include Node
        kind :font
        declaration!
        category :data
        operands name: :name, font: :font
      end

      class Raw
        include Node
        kind :raw
        tier :hardware_only
        category :control
        operands bytes: :text
      end

      class ReadScanline
        include Node
        kind :read_scanline
        tier :hardware_only
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
        declaration!
        category :data
        operands name: :name, bytes: :text, rate: :int, note: :option,
                 envelope: :shape, holds_from: :int
      end

      class SaveInit
        include Node
        kind :save_init
        category :var
        operands vars: :save, magic: :int
      end

      # THE THREE WAYS INTO SAVE MEMORY that save data is built from (see Builder::SaveData):
      # read a byte, a half or a word at a place in it, write one, and total a run of bytes
      # into a checksum. A place is a count of bytes from the start of save memory, and what
      # save memory IS — a chip, a file, a Ruby hash — is each backend's business.
      #
      # A read is unsigned for a byte and a half and a whole signed word for a word, so a
      # narrow list slot comes back the way the list itself reads a number too big for it.
      class SaveRead
        include Node
        kind :save_read
        category :value
        operands at: :value, width: :option
      end

      class SaveWrite
        include Node
        kind :save_write
        category :var
        operands at: :value, value: :value, width: :option
      end

      # The checksum of +length+ bytes from +at+: two running totals, the bytes and the totals
      # of the bytes, each kept to sixteen bits — the second is what makes it notice two bytes
      # swapped — with the second in the top half of the word. See IR::SaveLayout.checksum.
      class SaveSum
        include Node
        kind :save_sum
        category :value
        operands at: :value, length: :value
      end

      # HOW MUCH SAVE MEMORY THE PROGRAM HAS, in kilobytes (see IR::SaveLayout::MEMORIES), and
      # so which kind: the smallest takes any byte at any time, where the bigger ones have to be
      # wiped a block at a time before a block is written again (IR::SaveLayout::Memory says
      # which). A program that names none has the smallest.
      #
      # It also says how the size came about, for a report to read and nothing to run:
      # +asked_for+ is whether the program's author named it, and +records+ is each record laid
      # out in it as [name, half bytes, copies], in the order they were declared.
      class SaveMemory
        include Node
        kind :save_memory
        declaration!
        category :data
        operands kilobytes: :int, asked_for: :flag, records: :list
      end

      # Wipe the block of save memory that holds +at+, so it takes any write again, and reads
      # as never written. Memory wiped a block at a time needs this before a block is written
      # afresh; on memory that takes any byte it does nothing, so a write order is written once
      # for both.
      #
      # A wipe takes a while. With +wait+ the program goes on once it is done. Without, the wipe
      # is only started, so the program can do other work meanwhile: until it is done, the
      # program must not write to save memory or start another wipe, and a read of the block
      # does not read 0xFF. So the program reads the block's first byte until it reads 0xFF.
      class SaveErase
        include Node
        kind :save_erase
        category :var
        operands at: :value, wait: :flag
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

      # A tune. At +total_frames+ it comes round again — to its first frame, or to
      # +loop_frame+ when it has one, so an introduction plays once. Played as a sound effect, the
      # others of its +group+ are the effects it stops (IR::Tunes.priority_of).
      class Song
        include Node
        kind :song
        declaration!
        category :sound
        operands name: :name, voices: :score, total_frames: :int, loop_frame: :int, priority: :int,
                 group: :name
      end

      # A named list of songs that each play ONCE, over the tune playing now, when the program
      # asks for one (see PlaySoundEffect). A definition: it names what can be played and sounds
      # nothing.
      class SoundEffectList
        include Node
        kind :sound_effect_list
        declaration!
        category :sound
        operands name: :name, effects: :list
      end

      # Effect number +which+ of a SoundEffectList starts from its first note, counting from 0 — a
      # number that may be worked out as the program runs. Asked for while it is still sounding,
      # it starts again; a number naming no effect in the list plays nothing.
      class PlaySoundEffect
        include Node
        kind :play_sound_effect
        category :sound
        operands name: :name, which: :value
      end

      # A named list of songs, in order — the game's music, picked by number (see
      # PlayFromList). A definition, like Song: it names what can be played and sounds nothing.
      class SongList
        include Node
        kind :song_list
        declaration!
        category :sound
        operands name: :name, songs: :list
      end

      # The tune playing now is song number +which+ of a SongList, counting from 0 — a number
      # that may be worked out as the program runs. Like PlaySong, naming the tune already
      # playing changes nothing; a number naming no song in the list leaves the music as it is.
      class PlayFromList
        include Node
        kind :play_from_list
        category :sound
        operands name: :name, which: :value
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
        declaration!
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
        operands color: :color, amount: :value, fraction_bits: :int
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
        operands shape: :waveform, frequency: :int, volume: :option
      end

      # Every kind, by its name. Derived from the classes above rather than kept alongside
      # them, so it cannot fall behind: a class that exists is in here.
      BY_KIND = Ractor.make_shareable(constants.map { |name| const_get(name) }
                                               .to_h { |type| [type.kind, type] })

      def self.by_kind = BY_KIND

      # Every kind playing +role+ (see Node::Declarations#role), by name — what a backend's
      # handler table has to cover.
      BY_ROLE = Ractor.make_shareable(BY_KIND.group_by { |_kind, type| type.role }
                                             .transform_values { |pairs| pairs.map(&:first) })

      def self.of_role(role) = BY_ROLE.fetch(role, [])

      # Build a node of the named kind. The one place a kind SYMBOL becomes a class, for
      # callers that have the name rather than the type.
      def self.build(kind, children: [], source: nil, **operands)
        by_kind.fetch(kind) { raise ArgumentError, "no IR node kind #{kind.inspect}" }
               .new(children: children, source: source, **operands)
      end
    end
  end
end
