# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# What one op costs (lib/ruby_gba/ir/cost_model/pricing.rb): the per-op weights, and
# the rule that a node is charged for the arithmetic in its operands too.
class TestCostPricing < CostModelTest
  # Per-pixel collision is priced, never a silent zero, and it scales with the work —
  # the overlap rectangle it walks. The SAME game with 8x8 sprites vs 4x4 sprites differs
  # only in that area (the box gate and the sprite upkeep are identical), so the frame
  # cost delta is exactly the extra overlap pixels, each one an overlap_pixel.
  def overlap_game(size)
    program do
      screen :tiled
      image(:blk, "#" => :red) { (["#" * size] * size).join("\n") }
      a = sprite :blk, at: [10, 10]
      b = sprite :blk, at: [40, 40]
      game_loop do
        a.overlaps?(b).then { set :touch, 1 }
      end
    end
  end

  def test_per_pixel_collision_is_priced_by_overlap_area
    delta = Cost.new.frame_cost(overlap_game(8)) - Cost.new.frame_cost(overlap_game(4))
    near(((8 * 8) - (4 * 4)) * WEIGHTS[:overlap_pixel], delta)
  end

  # fill_rect writes every pixel itself; dma_fill_rect hands each row to the block-fill
  # engine. The split prices them apart — the same rectangle costs far more written out
  # by the CPU than filled by the engine.
  def test_fill_rect_is_priced_as_cpu_plotting_apart_from_dma
    w = 40
    h = 20
    cpu = program do
      screen :bitmap
      game_loop { fill_rect 0, 0, w, h, :red }
    end
    dma = program do
      screen :bitmap
      game_loop { dma_fill_rect 0, 0, w, h, :red }
    end
    near(frame_boundary + (w * h * WEIGHTS[:plot_run_pixel]), Cost.new.frame_cost(cpu))
    near(frame_boundary + (h * dma_start) + (w * h * WEIGHTS[:dma_pixel]), Cost.new.frame_cost(dma))
    assert_operator Cost.new.frame_cost(cpu), :>, Cost.new.frame_cost(dma), "CPU plotting is dearer than a DMA fill"
  end

  # --- what the quick memory is worth, which is not the same for every op ---

  # A routine kept in the console's quick memory runs about two and a half times faster, and
  # that is true of INSTRUCTIONS. A transfer is not instructions: the CPU writes a few
  # registers to set the copy going and is then stopped while a separate engine moves the
  # pixels, so where our code lives changes nothing about how long the copy takes.
  #
  # A whole-screen clear is one transfer and one row of register writes, so it is the extreme
  # case — almost all engine. Charging it the full speed-up read it at a third of its cost.
  def test_a_transfer_costs_about_the_same_wherever_its_code_lives
    clearing = program do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    slow = Cost.new.frame_cost(clearing)
    fast = Cost.new(fast_frame: true).frame_cost(clearing)
    assert_in_delta 1.0, fast / slow, 0.01, "a transfer gains nothing worth seeing"
  end

  # ...and the opposite extreme, which has to keep the whole factor. The frame's own boundary
  # sits in both readings and gains nothing either — the console does that waiting wherever
  # our code lives — so it comes off both sides before the factor is asked about.
  def test_arithmetic_gains_the_whole_speed_up
    adding = program do
      screen :bitmap
      n = var :n, 0
      game_loop { 100.times { n.add 1 } }
    end
    near((Cost.new.frame_cost(adding) - frame_boundary) / WEIGHTS[:fast_code_speedup],
         Cost.new(fast_frame: true).frame_cost(adding) - frame_boundary)
  end

  # WHERE A ROUTINE LIVES IS ITS OWN BUSINESS, not its caller's — and this is the one the
  # estimate got wrong for long enough to matter.
  #
  # A routine is emitted once and jumped to, so a routine the build could NOT fit into quick
  # memory runs from the cartridge however it was reached. Priced the other way round — the
  # frame's own body carrying its speed into everything it calls — a game is charged for quick
  # memory it does not have, and the report of what the build TURNED AWAY costs the same as the
  # report of what it kept. That is a hole rather than an approximation: the "did not fit" note
  # and the number underneath it would disagree, and only the note would be right.
  def calling_game
    program do
      screen :bitmap
      total = var :total, 0
      func(:worker) { 200.times { total.add 1 } }
      game_loop { call :worker }
    end
  end

  def test_a_routine_left_in_the_cartridge_is_priced_there_though_its_caller_moved
    left_behind = Cost.new(fast_frame: true).steady_cost(calling_game) - frame_boundary
    moved = Cost.new(fast_frame: true, fast_routines: [:worker]).steady_cost(calling_game) - frame_boundary

    assert_operator left_behind, :>, moved,
                    "a routine that did not fit cannot cost what one that did costs"
    near(moved * WEIGHTS[:fast_code_speedup], left_behind)
  end

  # ...and the frame body's own placement still counts for the frame body's own statements,
  # which is what stops the fix above from simply turning the discount off.
  def test_the_frames_own_body_still_gains_when_it_moved
    inline = program do
      screen :bitmap
      total = var :total, 0
      game_loop { 200.times { total.add 1 } }
    end

    near((Cost.new.steady_cost(inline) - frame_boundary) / WEIGHTS[:fast_code_speedup],
         Cost.new(fast_frame: true).steady_cost(inline) - frame_boundary)
  end

  # A routine that DID move gains, even when whatever called it did not — the same rule read
  # the other way, and the reason this is about the routine rather than about nesting.
  def test_a_routine_that_moved_gains_though_its_caller_did_not
    near((Cost.new(fast_routines: [:worker]).steady_cost(calling_game) - frame_boundary) *
         WEIGHTS[:fast_code_speedup],
         Cost.new.steady_cost(calling_game) - frame_boundary)
  end

  # The arithmetic in between, stated exactly: a fill's register writes are discounted, its
  # engine start-up and its pixels are not.
  def test_a_fill_discounts_its_register_writes_and_not_its_transfer
    w = 40
    h = 20
    fill = program do
      screen :bitmap
      game_loop { dma_fill_rect 0, 0, w, h, :red }
    end
    engine = (h * WEIGHTS[:dma_engine_start]) + (w * h * WEIGHTS[:dma_pixel])
    cpu = h * WEIGHTS[:dma_cpu_start]
    near(frame_boundary + (cpu / WEIGHTS[:fast_code_speedup]) + engine,
         Cost.new(fast_frame: true).frame_cost(fill))
  end

  # The same line, on the OTHER screen. A moving rectangle wide enough to be worth starting
  # the engine for hands it the run and then waits, so that wait is the engine's and not the
  # code's — priced together with the register writes, the wait got a discount it can never
  # earn, and a tear-free game read cheap for the same reason a bitmap one did.
  def test_a_moving_rectangle_discounts_its_register_writes_and_not_its_transfer
    w = 40
    h = 20
    rect = program do
      screen :bitmap, tear_free: true
      y = var :y, 0
      game_loop { draw_rect_at 40, y, w, h, :red } # an even column: no ends to splice
    end
    engine = h * (WEIGHTS[:tearfree_engine_stall] + (w * WEIGHTS[:tearfree_fill_pixel]))
    cpu = WEIGHTS[:tearfree_moving_start] + var_reads + # the row it is drawn on is a variable
          (h * (WEIGHTS[:tearfree_row] + WEIGHTS[:tearfree_engine_start]))
    near(frame_boundary + (cpu / WEIGHTS[:fast_code_speedup]) + engine,
         Cost.new(fast_frame: true).frame_cost(rect))
  end

  # A blit costs its image's footprint (width x height), looked up from the bitmap
  # definition — so a game's sprites weigh in the estimate, not silently as zero.
  def test_blit_costs_its_image_footprint
    prog = Build.program(
      Build.screen(:bitmap),
      Build.bitmap(:ship, width: 8, height: 4, pixels: Array.new(32, 0).pack("v*"), transparent: nil),
      Build.loop_(Build.wait_vblank, Build.blit(:ship, Build.int(0), Build.int(0))),
    )
    near frame_boundary + dma_rows(8, 4), Cost.new.steady_cost(prog) # opaque: one DMA per row
    near frame_boundary + dma_rows(8, 4), Cost.new.frame_cost(prog)
  end

  # A DMA fill costs per ROW (each row is a DMA), so a tall-thin rectangle costs more
  # than a wide-flat one of the SAME pixel area.
  def test_a_tall_rect_costs_more_than_a_wide_one_of_equal_area
    tall = program { screen(:bitmap); dma_fill_rect(0, 0, 4, 40, :red); halt }   # 40 rows
    wide = program { screen(:bitmap); dma_fill_rect(0, 0, 40, 4, :red); halt }   # 4 rows, same 160px
    assert_operator Cost.new.frame_cost(tall), :>, Cost.new.frame_cost(wide),
                    "more rows = more DMA setups = more cost, even at equal area"
  end

  # An opaque image streams by DMA; a transparent one is plotted pixel by pixel, so
  # it costs far more for the same size.
  def test_a_transparent_blit_costs_more_than_an_opaque_one
    def blit_of(transparent)
      Build.program(
        Build.screen(:bitmap),
        Build.bitmap(:s, width: 8, height: 8, pixels: Array.new(64, 0).pack("v*"),
                         transparent: transparent),
        Build.loop_(Build.wait_vblank, Build.blit(:s, Build.int(0), Build.int(0))),
      )
    end
    assert_operator Cost.new.steady_cost(blit_of(0x8000)), :>, Cost.new.steady_cost(blit_of(nil))
  end

  # A STRETCHED COLUMN IS PRICED BY WHAT IS IN THE PICTURE, not by how tall it is drawn. The
  # console walks the stretches of rows that hold pixels and skips the see-through ones, so a
  # scaled sprite of a lamp in a square of nothing costs a fraction of a solid one the same
  # size — which is the difference between a first-person view that fits in a frame and one
  # that does not.
  def test_a_stretched_column_costs_what_the_picture_holds_not_its_height
    def column_of(pixels, transparent)
      Build.program(
        Build.screen(:bitmap),
        Build.bitmap(:s, width: 1, height: 8, pixels: pixels.pack("v*"), transparent: transparent),
        Build.loop_(Build.wait_vblank,
                    Build.draw_column_at(:s, Build.int(0), Build.int(0), Build.int(0),
                                         Build.int(64), width: 1)),
      )
    end

    solid = column_of(Array.new(8, 0x1234), nil)
    # The same picture with the middle six rows see-through: a quarter of it is really there.
    mostly_gone = column_of([0x1234, *Array.new(6, 0x8000), 0x1234], 0x8000)

    assert_operator Cost.new.steady_cost(mostly_gone), :<, Cost.new.steady_cost(solid),
                    "a picture that is mostly see-through walks fewer rows"
  end

  # The cost model reads the node's font, so a denser/bigger font costs more: the
  # same digits drawn in the compact :tiny font plot fewer pixels than in :default.
  def test_the_cost_of_text_follows_the_node_font
    default = program { screen(:bitmap); draw_text("42", 0, 0, :white); halt }
    tiny    = program { screen(:bitmap); draw_text("42", 0, 0, :white, font: :tiny); halt }
    near text_cost("42", :default), Cost.new.frame_cost(default)
    near text_cost("42", :tiny), Cost.new.frame_cost(tiny)
    assert_operator Cost.new.frame_cost(tiny), :<, Cost.new.frame_cost(default), "tiny should cost less"
  end

  # A draw_number column is a single draw_digit node worth one digit — there's no
  # ten-way fan-out in the tree to discount, so a column's full and steady costs are
  # both just one digit (a 3-digit score is ~3 digits, not 30).
  def test_draw_number_column_costs_one_digit
    prog = program do
      screen :bitmap
      var :score, 0
      game_loop do
        draw_number :score, 8, 8, :white, digits: 1 # one column -> one draw_digit
      end
    end
    # digits:1 draws exactly one digit — plus the cheap arithmetic to pull it out of the
    # number. So the cost is one digit's worth and change, never a phantom fan-out to more
    # columns (which would be two digits or more).
    assert_operator Cost.new.steady_cost(prog), :>=, digit_cost
    assert_operator Cost.new.steady_cost(prog), :<, 2 * digit_cost
    assert_operator Cost.new.frame_cost(prog), :>=, digit_cost
    assert_operator Cost.new.frame_cost(prog), :<, 2 * digit_cost
  end

  # A LIVE digit is not a line of text, and pricing it as one was most of the way to free.
  # Text has its pixels settled while building — the console is told exactly which to write.
  # A live digit cannot be: which of the ten shows is only known as the game runs, so the
  # console walks the chosen glyph out of a table instead, which is a different order of
  # work from writing a glyph it already knows.
  def test_a_live_digit_costs_far_more_than_the_same_glyph_as_fixed_text
    live = program do
      screen :bitmap
      var :score, 0
      game_loop { draw_number :score, 8, 8, :white, digits: 1 }
    end
    fixed = program { screen(:bitmap); game_loop { draw_text "8", 8, 8, :white } }

    assert_operator Cost.new.steady_cost(live), :>, 4 * Cost.new.steady_cost(fixed),
                    "walking a glyph out of a table dwarfs writing one settled while building"
  end

  # The walk tests EVERY cell of the digit's box, lit or not — and most of a digit's box is
  # not lit. Charging only the lit ones was the whole of the mistake.
  def test_a_live_digit_pays_for_the_cells_it_does_not_light
    prog = program do
      screen :bitmap
      var :score, 0
      game_loop { draw_number :score, 8, 8, :white, digits: 1 }
    end
    lit_only = RubyGBA::Fonts.get(:default).max_glyph_pixels(("0".."9").to_a) * WEIGHTS[:digit_pixel]

    assert_operator Cost.new.steady_cost(prog), :>, 3 * lit_only,
                    "the box costs more to walk than its lit cells cost to stamp"
  end

  # A digit in a smaller font is cheaper on two counts, not one: fewer cells to light AND a
  # smaller box to walk. So the gap between the two fonts is wider than their lit pixels
  # alone can explain — which is only true because the box is priced at all.
  def test_a_digit_in_a_smaller_font_has_less_box_to_walk
    big = program do
      screen :bitmap
      var :score, 0
      game_loop { draw_number :score, 8, 8, :white, digits: 1 }
    end
    small = program do
      screen :bitmap
      var :score, 0
      game_loop { draw_number :score, 8, 8, :white, digits: 1, font: :tiny }
    end

    digits = ("0".."9").to_a
    lit_gap = RubyGBA::Fonts.get(:default).max_glyph_pixels(digits) -
              RubyGBA::Fonts.get(:tiny).max_glyph_pixels(digits)
    assert_operator Cost.new.steady_cost(big) - Cost.new.steady_cost(small), :>,
                    lit_gap * WEIGHTS[:digit_pixel],
                    "the bigger font is more box to walk, not only more cells to light"
  end

  # --- tiled-mode per-frame upkeep is no longer free (gba-86vh) ---

  # Presenting sprites costs one position rewrite per sprite (the display composites
  # them for free, but moving them each frame is real CPU work).
  def test_present_objects_costs_one_update_per_sprite
    prog = Build.program(
      Build.screen(:tiled),
      Build.loop_(Build.wait_vblank, Build.present_objects(%i[hero ghost coin])),
    )
    near frame_boundary + (3 * WEIGHTS[:obj_write]), Cost.new.steady_cost(prog)
  end

  # Scrolling a background costs its two scroll-register writes; constant offsets are
  # free to evaluate.
  def test_scroll_background_costs_its_scroll_writes
    prog = Build.program(
      Build.screen(:tiled),
      Build.loop_(Build.wait_vblank, Build.scroll_background(:world, x: Build.int(4), y: Build.int(0))),
    )
    near frame_boundary + WEIGHTS[:scroll_write], Cost.new.steady_cost(prog)
  end

  # ...and a REAL one reads where the window sits out of the two variables the framework keeps
  # it in, which is charged where the read is rather than inside the weight. The weight is
  # measured with those two taken back out, so the two halves have to meet here: miss the reads
  # and every scrolling game is under-charged, leave them inside the weight as well and a
  # scrolling game pays for reaching its own position twice.
  def test_a_scrolling_background_also_pays_for_reading_where_its_window_sits
    prog = Build.program(
      Build.screen(:tiled),
      Build.set(:sx, Build.int(0)), Build.set(:sy, Build.int(0)),
      Build.loop_(Build.wait_vblank,
                  Build.scroll_background(:world, x: Build.var_ref(:sx), y: Build.var_ref(:sy))),
    )
    near frame_boundary + WEIGHTS[:scroll_write] + var_reads(2), Cost.new.steady_cost(prog)
  end

  # Moving the camera and setting the fade redraw nothing, so they are cheap — but not
  # free, and `shake_screen` moves the camera on every frame it runs. Counting them as
  # free made the estimate announce it could not price them and hedge every verdict on
  # a game that shakes.
  def test_moving_the_camera_and_fading_are_priced
    prog = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.camera(x: Build.int(3), y: Build.int(5))),
    )
    near frame_boundary + WEIGHTS[:camera_move], Cost.new.steady_cost(prog)

    fading = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.fade(toward: :black, amount: Build.int(50))),
    )
    near frame_boundary + WEIGHTS[:fade_set], Cost.new.steady_cost(fading)
  end

  # The hardware counts a fade in sixteenths, so a level the GAME works out has to be
  # converted as the program runs — a multiply and a divide the tree cannot see, because
  # the lowering builds them. A level written into the program is converted while
  # building and costs nothing extra.
  def test_a_fade_the_game_works_out_costs_the_conversion
    fixed = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.fade(toward: :black, amount: Build.int(50))),
    )
    live = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.fade(toward: :black, amount: Build.var_ref(:level))),
    )
    assert_operator Cost.new.steady_cost(live), :>, Cost.new.steady_cost(fixed)
    # A SHIFT, not a multiply: the hardware counts a fade in SIXTEENTHS, so converting a
    # percentage multiplies by 16 — a power of two — and the console shifts instead.
    near frame_boundary + WEIGHTS[:fade_set] + WEIGHTS[:op_mul_pow2] + WEIGHTS[:op_div_const] +
         var_reads,
         Cost.new.steady_cost(live), "the conversion, and reading the level it converts"
  end

  # A TINT COSTS TWO QUITE DIFFERENT THINGS, and the screen decides which. On the
  # direct-color screen the display blends the finished picture and the tint is two
  # register writes. On a screen drawn through a color table it cannot, so the framework
  # moves every color the game declared — and that is the number this must charge, or a
  # game would read a real per-frame cost as free.
  def test_a_tint_on_a_table_drawn_screen_is_priced_per_color
    direct = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.tint(color: :red, amount: Build.int(50))),
    )
    buffered = Build.program(
      Build.screen(:bitmap, buffered: true),
      Build.loop_(Build.wait_vblank, Build.tint(color: :red, amount: Build.int(50))),
    )

    near frame_boundary + WEIGHTS[:tint_set], Cost.new.steady_cost(direct)
    near frame_boundary + WEIGHTS[:tint_hold] + (ENTRIES * WEIGHTS[:tint_entry]),
         Cost.new(palette_entries: { buffered: ENTRIES }).steady_cost(buffered)
  end

  ENTRIES = 34 # what a build would have told the estimate its table holds

  # With no build behind the estimate there is nothing to ask, so a full table is
  # assumed — the dearest answer rather than a cheap guess.
  def test_a_tint_with_no_build_behind_it_is_priced_on_a_full_table
    program = Build.program(
      Build.screen(:bitmap, buffered: true),
      Build.loop_(Build.wait_vblank, Build.tint(color: :red, amount: Build.int(50))),
    )

    near frame_boundary + WEIGHTS[:tint_hold] + (256 * WEIGHTS[:tint_entry]), Cost.new.steady_cost(program)
  end

  # ...and the tree says so, because a reader with no idea that a table exists cannot
  # otherwise tell why one `tint` costs a hundred times another.
  def test_the_tree_names_the_colors_a_tint_moves
    program = Build.program(
      Build.screen(:bitmap, buffered: true),
      Build.loop_(Build.wait_vblank, Build.tint(color: :red, amount: Build.int(50))),
    )
    tint = leaves(Cost.new(palette_entries: { buffered: ENTRIES }).analyze(program))
           .find { |leaf| leaf.op == :tint }

    assert_includes tint.label, "#{ENTRIES} colors"
  end

  # Save memory sits on a slow bus and takes a byte at a time, so keeping a counter in a
  # `save_var` costs several times what keeping it in an ordinary one does — every change
  # mirrors it back. Worth seeing rather than counting as free.
  def test_changing_a_saved_variable_costs_more_than_changing_an_ordinary_one
    ordinary = program do
      screen :bitmap
      score = var :score, 0
      game_loop { score.add 1 }
    end
    saved = program do
      screen :bitmap
      score = save_var :score, 0
      game_loop { score.add 1 }
    end
    near frame_boundary + WEIGHTS[:op_step], Cost.new.steady_cost(ordinary)
    near frame_boundary + WEIGHTS[:op_step] + WEIGHTS[:save_write], Cost.new.steady_cost(saved)
  end

  # Both are display writes the visible frame must not catch part-done, so they belong to
  # the drawing the tear check judges — not to the logic that runs through the frame.
  def test_the_camera_and_the_fade_count_as_drawing
    prog = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank,
                  Build.camera(x: Build.int(3), y: Build.int(5)),
                  Build.fade(toward: :black, amount: Build.int(50))),
    )
    near frame_boundary + WEIGHTS[:camera_move] + WEIGHTS[:fade_set], Cost.new.steady_tear_cost(prog)
  end

  # Loading the saved variables happens once at boot, before the first frame, so it is
  # declared free rather than left to the "cannot estimate" banner — the banner is for
  # work nobody has decided about yet.
  def test_a_program_that_saves_is_fully_priced
    prog = program do
      screen :bitmap
      best = save_var :best, 0
      game_loop { best.add 1; camera 1, 1; fade :black, 25 }
    end
    assert_empty Cost.new.unpriced_kinds(prog)
  end

  # A divide is priced well above an add, because on this CPU it traps into the BIOS
  # Div routine rather than running as a single instruction.
  def test_a_divide_costs_more_than_an_add
    adder = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x + 1) }
    end
    divider = program do
      screen :bitmap
      x = var :x, 100
      d = var :d, 100
      game_loop { x.set(x / d) }
    end

    assert_operator Cost.new.steady_cost(divider), :>, Cost.new.steady_cost(adder),
                    "a divide (BIOS routine) should cost more than an add"
  end

  # Going round a loop is real work — a count, a test, a jump back — and it is paid once
  # per pass like everything in the body. Charging nothing for it made a tight loop over a
  # cheap body read as almost free: 900 passes of an empty body cost 54 scanlines on the
  # console and the model called them 0.
  def test_a_loop_pass_is_not_free
    empty = program do
      screen :bitmap
      game_loop { repeat(100) { |_i| nil } }
    end
    near frame_boundary + WEIGHTS[:loop_start] + (100 * WEIGHTS[:loop_pass]), Cost.new.steady_cost(empty)
  end

  # A LOOP IS TWO COSTS AND ONLY ONE OF THEM SCALES. Each pass counts, tests and jumps back;
  # entering the loop works its trip count out into a hidden limit and zeroes a hidden counter,
  # once, whatever it then does. So ten passes cost ten passes plus ONE entering — not ten
  # times what one pass costs — and the shorter the loop the more of it is simply being a loop.
  def test_entering_a_loop_costs_the_same_however_many_passes_it_makes
    passes = lambda do |n|
      Cost.new.steady_cost(program do
        screen :bitmap
        game_loop { repeat(n) { |_i| nil } }
      end)
    end

    near WEIGHTS[:loop_pass], passes.call(11) - passes.call(10), "one more pass is one more pass"
    near frame_boundary + WEIGHTS[:loop_start] + WEIGHTS[:loop_pass], passes.call(1),
         "and a loop of one is the entering, plus its single pass"
  end

  # IT IS BOOKKEEPING, AND IT STILL TEARS THE PICTURE. Going round a loop draws nothing, so
  # the tear check used to leave it out — only drawing races the vblank window, the thinking
  # went. That is true of the WRITE and false of the DEADLINE: what tears is a write landing
  # after the safe window closed, and a hundred passes of counting push every write in the
  # loop that much later. Measured on the console, a thousand passes of plain arithmetic
  # ahead of a single pixel put that pixel on scanline 11, in the middle of the picture.
  def test_a_loop_pass_counts_toward_tearing_because_it_delays_the_drawing
    prog = program do
      screen :bitmap
      game_loop { repeat(100) { |_i| dma_fill_rect 0, 0, 8, 8, :red } }
    end
    cost = Cost.new

    near frame_boundary + loop_cost(100, dma_rows(8, 8)), cost.steady_tear_cost(prog)
    near cost.steady_cost(prog), cost.steady_tear_cost(prog),
         "everything here happens before the last draw, so both measures see all of it"
  end

  # ...and work AFTER the last draw does not, which is the other half of the same fact. A
  # frame that draws first and thinks afterwards has nothing left to push out of the window.
  def test_work_after_the_last_draw_does_not_count_toward_tearing
    thinks_first = program do
      screen :bitmap
      n = var :n, 0
      game_loop { repeat(100) { n.add 1 }; dma_fill_rect 0, 0, 8, 8, :red }
    end
    draws_first = program do
      screen :bitmap
      n = var :n, 0
      game_loop { dma_fill_rect 0, 0, 8, 8, :red; repeat(100) { n.add 1 } }
    end

    near frame_boundary + dma_rows(8, 8), Cost.new.steady_tear_cost(draws_first)
    # The frame's own boundary is ahead of the draw in both, so it comes off both before the
    # spread is asked about — what is being compared is where the PROGRAM put its work.
    assert_operator Cost.new.steady_tear_cost(thinks_first) - frame_boundary, :>,
                    (Cost.new.steady_tear_cost(draws_first) - frame_boundary) * 10,
                    "the same work ahead of the draw is what pushes it out of the window"
    near Cost.new.steady_cost(thinks_first), Cost.new.steady_cost(draws_first),
         "the frame costs the same either way — only the tear risk moves"
  end

  # A division worked out as the program runs walks its answer one bit at a time, so a
  # wide answer costs more than a narrow one — up to two and a third times more. An answer
  # can be no wider than its numerator, so a numerator written into the program bounds it
  # exactly. This is the `WALL_HEIGHT / distance` shape.
  def test_a_wide_answer_costs_more_than_a_narrow_one
    costs = [3, 255, 1_073_741_823].map do |numerator|
      prog = program do
        screen :bitmap
        d = var :d, 7
        out = var :out, 0
        game_loop { out.set(numerator / d) }
      end
      # What the divide costs, so the frame's own boundary — the same in all three — cannot
      # narrow the spread being asserted on.
      Cost.new.steady_cost(prog) - frame_boundary
    end
    assert_equal costs.sort, costs, "a wider answer must not cost less"
    assert_operator costs.last, :>, costs.first * 1.5, "and the spread has to be worth pricing"
    # 3 is 2 bits wide; the divisor is the one variable read.
    near WEIGHTS[:op_assign] + WEIGHTS[:op_div] + (2 * WEIGHTS[:op_div_bit]) + var_reads, costs.first
  end

  # With nothing to bound the answer the price is the base alone — deliberately, because
  # game code divides for coordinates and percentages, whose answers sit within about a
  # seventh of it either way. The reasoning is written out at runtime_divide_weight.
  def test_an_unbounded_answer_is_priced_at_the_base
    prog = program do
      screen :bitmap
      n = var :n, 1_073_741_823
      d = var :d, 7
      out = var :out, 0
      game_loop { out.set(n / d) }
    end
    near frame_boundary + WEIGHTS[:op_assign] + WEIGHTS[:op_div] + var_reads(2),
         Cost.new.steady_cost(prog)
  end

  # Dividing has three prices, because the lowering gives it three costs, and an author
  # reading `explain` has to be able to tell them apart: by a power of two it is a
  # shift, by any other fixed number a multiply by a reciprocal, and only by a number
  # the game works out is it the BIOS routine.
  def test_a_divide_is_priced_by_where_its_divisor_comes_from
    costs = [->(x, _d) { x / 256 }, ->(x, _d) { x / 100 }, ->(x, d) { x / d }].map do |divide|
      prog = program do
        screen :bitmap
        x = var :x, 100
        d = var :d, 100
        game_loop { x.set(divide.call(x, d)) }
      end
      Cost.new.steady_cost(prog)
    end

    assert_operator costs[0], :<, costs[1], "a shift should beat a multiply by a reciprocal"
    assert_operator costs[1], :<, costs[2], "a reciprocal should beat calling the divide routine"
  end

  # ...but not every divide is that. By a power of two the console shifts instead of
  # calling, so the estimate has to say so — otherwise it would send an author chasing a
  # cost that is not there. This is the same fact the lowering acts on.
  #
  # It is CHEAPER than an add, not equal to one, which is what this used to assert. A shift
  # rounds down where `/` rounds toward zero, so a divide by a power of two is the shift plus
  # the nudge that fixes a negative numerator — three instructions against an add's four.
  def test_a_divide_by_a_power_of_two_costs_less_than_an_add
    adder = arithmetic_loop { |x| x + 1 }
    halver = arithmetic_loop { |x| x / 256 }

    assert_operator Cost.new.steady_cost(halver), :<, Cost.new.steady_cost(adder)
    near WEIGHTS[:op_div_pow2], Cost.new.steady_cost(halver) - Cost.new.steady_cost(assignment_loop)
  end

  # Multiplying by a power of two and wrapping onto one cost the SAME as each other and less
  # than either — one instruction apiece. A shift is a shift, and keeping a number's low bits
  # is already the answer to `% 64`, sign and all, so that is a mask. They are the two
  # cheapest operators there are, and the model used to charge them a whole plain step.
  def test_multiplying_and_wrapping_by_a_power_of_two_are_the_cheapest_operators
    doubler = arithmetic_loop { |x| x * 64 }
    wrapper = arithmetic_loop { |x| x % 64 }

    near Cost.new.steady_cost(doubler), Cost.new.steady_cost(wrapper)
    near WEIGHTS[:op_mul_pow2], Cost.new.steady_cost(doubler) - Cost.new.steady_cost(assignment_loop)
    assert_operator Cost.new.steady_cost(doubler), :<, Cost.new.steady_cost(arithmetic_loop { |x| x / 256 }),
                    "a shift alone beats a shift that has to round"
  end

  # Dropping a fraction to get a whole number is the same single shift a multiply by a power
  # of two is, and measures at the same price — so it is charged the same weight. This is
  # what `.to_i` lowers to, and a game holding fractions writes it on every coordinate it
  # draws, so charging it a whole plain step put six instructions where one runs.
  def test_dropping_a_fraction_costs_the_same_as_a_shift
    dropped = program do
      screen :bitmap
      p = var :px, 3.5
      out = var :out, 0
      game_loop { out.set p.to_i }
    end
    shifted = program do
      screen :bitmap
      x = var :x, 100
      out = var :out, 0
      game_loop { out.set(x * 8) }
    end

    near Cost.new.steady_cost(shifted), Cost.new.steady_cost(dropped)
  end

  # THE FOUR SHAPES OF PLAIN WORK, which used to be one weight — `add :x, 1`, measured once
  # and then charged for a `set`, for an operator, and for a comparison. They are four
  # prices, and the tests below pin each apart from the others.

  # A statement that changes a variable it already holds has to reach that variable at both
  # ends. One that only writes it reaches it once, so it is the cheaper of the two — about
  # three quarters. Charging the first for both read every assignment a third over.
  def test_changing_a_variable_costs_more_than_only_writing_one
    changed = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.add 1 }
    end

    assert_operator Cost.new.steady_cost(changed), :>, Cost.new.steady_cost(assignment_loop)
    near frame_boundary + WEIGHTS[:op_step], Cost.new.steady_cost(changed)
    near frame_boundary + WEIGHTS[:op_assign] + var_reads, Cost.new.steady_cost(assignment_loop)
  end

  # An operator is charged BESIDE the statement that holds it, so its weight has to be what it
  # ADDS and not a statement over again. Building it out of a statement charged the statement
  # twice, and that is what made `x.set(x + 1)` read a third over.
  #
  # The check is the difference between two whole programs, which is the only form that can say
  # this: a program with the operator, minus the same program without it, has to come to the
  # operator's weight and nothing more. It used to be checked a second way — that an operator
  # weighs less than the statement around it — and that has stopped being a fact about this
  # console. A statement is now a base into a register and one store, where an operator holds
  # one side on the stack while it works out the other; the statement is the cheaper of the two.
  # An inequality that is no longer true guards nothing, and asserting it would only pin the
  # model to a machine that has changed.
  def test_a_plain_operator_is_charged_for_what_it_adds_and_not_the_statement_again
    added = arithmetic_loop { |x| x + 1 }

    near WEIGHTS[:op_plain], Cost.new.steady_cost(added) - Cost.new.steady_cost(assignment_loop)
  end

  # EVERY VARIABLE A STATEMENT READS IS CHARGED, and that is something no weight can do on
  # its own: a weight is one number, measured on a benchmark that read the operands it read.
  # `set :y, x` reads one variable and a plain operator's benchmark is handed the NUMBER 2 —
  # so between them they could pay for one read and never for two, and the second read was
  # free. `n.set(m + p)` is the shape that catches it, and it is not a corner: it is what a
  # game writes wherever one thing follows another.
  def test_a_statement_is_charged_for_every_variable_it_reads
    one = pair_loop { |m, _p| m + 1 }
    two = pair_loop { |m, p| m + p }

    near frame_boundary + WEIGHTS[:op_assign] + WEIGHTS[:op_plain] + var_reads, Cost.new.steady_cost(one)
    near frame_boundary + WEIGHTS[:op_assign] + WEIGHTS[:op_plain] + var_reads(2), Cost.new.steady_cost(two)
    near var_reads, Cost.new.steady_cost(two) - Cost.new.steady_cost(one),
         "the two statements differ by one operand, so they differ by one read"
  end

  # ...and a statement that reads NO variable is not charged for one. The weight used to carry
  # the read its own benchmark did, so `n.set 5` — every counter reset in every game — was
  # charged a read it never does.
  def test_a_statement_that_reads_no_variable_is_not_charged_for_one
    near frame_boundary + WEIGHTS[:op_assign], Cost.new.steady_cost(pair_loop { |_m, _p| 5 })
  end

  # A `copy` reads a variable as well, and NAMES it where a `set` holds it as an expression.
  # So its read has nowhere to be found and has to be charged beside the statement — the two
  # shapes do the same work and must not cost different amounts because of how the tree says
  # it.
  def test_a_copy_costs_what_the_same_assignment_costs
    copied = program do
      screen :bitmap
      var :n, 0
      var :m, 7
      game_loop { copy :n, :m }
    end

    near frame_boundary + WEIGHTS[:op_assign] + var_reads, Cost.new.steady_cost(copied)
    near Cost.new.steady_cost(assignment_loop), Cost.new.steady_cost(copied)
  end

  # `n.set(<something worked out from m and p>)` once a frame. Three variables in every
  # program here, so which of them a statement reads is the only thing that differs.
  def pair_loop(&expr)
    program do
      screen :bitmap
      n = var :n, 0
      m = var :m, 7
      p = var :p, 3
      game_loop { n.set(expr.call(m, p)) }
    end
  end

  # A comparison is dearer than an add, which nothing about `>` suggests. Adding two numbers
  # IS the answer; comparing them only sets the console's flags, and the answer still has to
  # be turned into a 1 or a 0 — which takes a jump over one of them. Comparisons are not
  # rare, so getting this wrong is not a corner: every `.then` holds one.
  def test_a_comparison_costs_more_than_a_plain_operator
    compared = Cost.new.steady_cost(value_loop(Build.binop(:>, Build.var_ref(:x), Build.int(1))))
    added = Cost.new.steady_cost(value_loop(Build.binop(:+, Build.var_ref(:x), Build.int(1))))
    bare = Cost.new.steady_cost(value_loop(Build.var_ref(:x)))

    assert_operator compared, :>, added
    near WEIGHTS[:op_compare], compared - bare
    near WEIGHTS[:op_plain], added - bare
  end

  # An operator the model has never heard of is charged the DEARER tier, not the cheaper —
  # so an operator added later and forgotten here reads over rather than under, which is the
  # only direction an estimate can afford to be wrong in.
  def test_an_operator_with_no_tier_of_its_own_is_charged_the_dearer_one
    unknown = Cost.new.steady_cost(value_loop(Build.binop(:nor, Build.var_ref(:x), Build.int(1))))

    near WEIGHTS[:op_compare], unknown - Cost.new.steady_cost(value_loop(Build.var_ref(:x)))
  end

  # Turning a number round is one instruction — the same single instruction a shift is, and
  # measured at the same price, so it shares that weight. It used to be charged a whole
  # plain step: six instructions for one.
  def test_turning_a_number_round_costs_what_a_shift_costs
    flipped = Cost.new.steady_cost(value_loop(Build.neg(Build.var_ref(:x))))

    near WEIGHTS[:op_mul_pow2], flipped - Cost.new.steady_cost(value_loop(Build.var_ref(:x)))
  end

  # WHERE A VARIABLE SITS COSTS NOTHING, and it once cost a great deal — which is why these
  # tests are still here saying the difference is nought rather than being deleted.
  #
  # Reaching a variable began by building its whole address, and a bigger address took another
  # instruction to build: one for the very first variable, two for the next sixty-three, three
  # past that. A list of 64 claims the first 256 bytes of the console's quick memory before any
  # variable gets a home, so in a game with a list every statement paid that at each end — and
  # which variables a game paid for came down to the order the build emitted things in.
  #
  # A read now names the BASE of that memory, which this console can hold in a register in one
  # instruction, and carries the variable's distance inside the load. The hundredth variable
  # costs what the first does.
  ORDINARY_VAR = 0x03000010
  DISTANT_VAR = 0x03000110 # past the first 256 bytes, where the address used to cost more

  def test_where_a_variable_sits_costs_the_same_wherever_it_is
    at = ->(address) { Cost.new(var_addresses: { x: address }).steady_cost(assignment_loop) }

    near frame_boundary + WEIGHTS[:op_assign] + var_reads, at.call(ORDINARY_VAR)
    near frame_boundary + WEIGHTS[:op_assign] + var_reads, at.call(DISTANT_VAR)
    near frame_boundary + WEIGHTS[:op_assign] + var_reads, at.call(0x03000000), "...including the first of all"
  end

  # An `add` reaches its variable at both ends where a `set` only writes, so distance would
  # have cost it twice over. It costs it nothing twice over.
  def test_a_statement_that_reaches_its_variable_twice_is_not_charged_for_distance
    changed = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.add 1 }
    end

    near frame_boundary + WEIGHTS[:op_step], Cost.new(var_addresses: { x: DISTANT_VAR }).steady_cost(changed)
  end

  # THE TWO WAYS TO HAVE NO ANSWER, which price the same and mean different things.
  #
  # No build behind the program at all is the first: nothing was ever worked out, so every
  # variable is ordinary. A build that simply never saw this name is the second — the map
  # answers about the program it was given, and a caller may be pricing a slightly different
  # one. Both fall back to ordinary, which is the safe way to be wrong; what the model can
  # say is which of the two it is in.
  def test_a_program_with_no_build_behind_it_prices_every_variable_the_same
    near frame_boundary + WEIGHTS[:op_assign] + var_reads, Cost.new.steady_cost(assignment_loop)
    near frame_boundary + WEIGHTS[:op_assign] + var_reads,
         Cost.new(var_addresses: {}).steady_cost(assignment_loop)
  end

  def test_a_name_the_build_never_saw_is_priced_as_ordinary_too
    built = Cost.new(var_addresses: { somewhere_else: 0x03007F00 })

    near frame_boundary + WEIGHTS[:op_assign] + var_reads, built.steady_cost(assignment_loop)
  end

  # ...and the two are told apart, which the fallback alone cannot say.
  def test_the_model_says_whether_a_build_stands_behind_it
    assert_predicate Cost.new(var_addresses: {}).var_addresses, :known?
    refute_predicate Cost.new.var_addresses, :known?
  end

  # END TO END, on a really built ROM rather than a map handed to the model. The two programs
  # do the same statement; one also declares a list, which claims the first 256 bytes of quick
  # memory before any variable gets a home — so every variable in it sits where an address used
  # to cost an instruction more at each end. They cost the same now, and this is the test that
  # would notice that stopping being true.
  def test_declaring_a_list_does_not_make_the_statements_around_it_dearer
    costs = [false, true].map do |with_list|
      rom = RubyGBA.build("VARS", code: "VARS", maker: "01", err: StringIO.new) do
        screen :bitmap
        list(:xs, capacity: 64) if with_list
        n = var :n, 0
        m = var :m, 7
        game_loop { n.set m }
      end
      rom.cost_model.steady_cost(rom.source_program)
    end

    # Two instructions — the read and the store — wherever the two variables landed. Counted
    # off the build rather than taken from :op_assign, which is the same claim for a program
    # that was never built.
    near frame_boundary + instructions(2), costs.first
    near frame_boundary + instructions(2), costs.last
  end

  # `set :out, <node>` once a frame. Built straight from the IR because the surface will not
  # let a comparison be assigned — there a comparison is a Condition, which belongs to
  # `.then` — and a branch around one would bring its own cost into the reading.
  def value_loop(node)
    Build.program(Build.screen(:bitmap), Build.loop_(Build.set(:out, node)))
  end

  # `x.set(<expr>)` once a frame, and the same assignment with nothing in the expression —
  # so differencing the two leaves the operator alone.
  def arithmetic_loop(&expr)
    program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(expr.call(x)) }
    end
  end

  def assignment_loop
    program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x) }
    end
  end

  # A wrap onto anything else has to work the leftover out, so it costs more than a step.
  def test_wrapping_onto_a_size_that_is_not_a_power_of_two_costs_more_than_a_step
    adder = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x + 1) }
    end
    wrapper = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x % 100) }
    end

    assert_operator Cost.new.steady_cost(wrapper), :>, Cost.new.steady_cost(adder)
  end

  # A collision test's comparison chain runs every frame, whether or not it hits, so
  # it carries a cost even when the response body is empty.
  def test_a_collision_condition_is_not_free
    prog = program do
      screen :bitmap
      x = var :x, 0
      hero = box x, 0, 8, 8
      wall = box 100, 0, 8, 8
      game_loop { hero.overlaps?(wall).then { nil } }
    end

    assert_operator Cost.new.steady_cost(prog), :>, 0,
                    "the overlaps? comparisons cost even with an empty body"
  end

  # --- logic / compute is no longer free (gba-lpak) ---

  # A loop whose body only does arithmetic — no drawing — still costs, and the cost
  # scales with how many times it runs. This is what lets the analysis see a
  # compute-bound loop (AI, physics) instead of reading it as free.
  def test_a_compute_loop_is_not_free_and_scales_with_its_count
    one = program do
      screen :bitmap
      var :x, 0
      game_loop { repeat(1) { add :x, 1 } }
    end
    ten = program do
      screen :bitmap
      var :x, 0
      game_loop { repeat(10) { add :x, 1 } }
    end
    # What the LOOP costs, with the frame's own boundary — the same in both — taken off.
    c_one = Cost.new.steady_cost(one) - frame_boundary
    c_ten = Cost.new.steady_cost(ten) - frame_boundary

    assert_operator c_one, :>, 0, "a compute loop is not free"
    # Ten passes cost ten passes — but only one entering, which the loop of one also paid.
    near WEIGHTS[:loop_start] + (10 * (WEIGHTS[:op_step] + WEIGHTS[:loop_pass])), c_ten
    assert_operator c_ten, :>, c_one * 5, "it still scales with the count"
  end

  # ---- reading one element of a list or a table ----

  # Both were once priced at nothing, on the grounds that a read is a single load. Neither
  # is. A list element sits in a ring, so reaching it means the head, the wrap, the scale to
  # bytes and the base before anything is loaded — thirteen instructions, all charged at
  # zero, in the middle of the loop a game spends its frame in.
  def test_reading_a_list_element_is_not_free
    bare = program do
      screen :bitmap
      list :xs, capacity: 64
      var :out, 0
      var :i, 3
      game_loop { set :out, 0 }
    end
    read = program do
      screen :bitmap
      xs = list :xs, capacity: 64
      out = var :out, 0
      i = var :i, 3
      game_loop { out.set xs[i] }
    end

    # The read, and the index it reads — which the program without it does not do.
    near WEIGHTS[:list_read] + var_reads, Cost.new.steady_cost(read) - Cost.new.steady_cost(bare)
  end

  # A TABLE read comes in two prices, and which one is settled by the table's LENGTH: a
  # power-of-two table keeps an out-of-range index inside it with a single mask, and any
  # other length clamps it to the ends with a compare and a branch per bound. Measured, the
  # clamping one is twice the wrapping one — and it is the one most tables a game writes by
  # hand are, so charging the cheap one for both would halve the price of the common case.
  def test_a_table_read_is_priced_by_whether_its_length_lets_the_index_wrap
    near WEIGHTS[:table_read] + var_reads, table_read_cost(64)
    near WEIGHTS[:table_read_clamped] + var_reads, table_read_cost(60)
    assert_operator WEIGHTS[:table_read_clamped], :>, WEIGHTS[:table_read] * 1.5,
                    "clamping is a compare and a branch per bound, not a mask"
  end

  # A read of a table the walk never saw has no length to judge, so it is charged the dearer
  # of the two — guessing the cheap one would under-estimate, which is the one direction
  # this model must not be wrong in.
  def test_a_table_that_was_never_declared_is_charged_the_dearer_read
    orphan = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.set(:out, Build.table_get(:missing, Build.int(0)))),
    )
    bare = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.set(:out, Build.int(0))),
    )

    near WEIGHTS[:table_read_clamped], Cost.new.steady_cost(orphan) - Cost.new.steady_cost(bare)
  end

  # What one read of a +length+-long table costs, with the `set` around it cancelled by the
  # same program without the read — so what is left is the read and the index it reads.
  def table_read_cost(length)
    with = program do
      screen :bitmap
      t = table :nums, (0...length).to_a
      out = var :out, 0
      i = var :i, 3
      game_loop { out.set t[i] }
    end
    without = program do
      screen :bitmap
      table :nums, (0...length).to_a
      var :out, 0
      var :i, 3
      game_loop { set :out, 0 }
    end
    Cost.new.steady_cost(with) - Cost.new.steady_cost(without)
  end

  # ---- operands are priced wherever they are written ----

  # The arithmetic that works out an index is arithmetic like any other, and the brackets
  # must make no difference to it: pricing an index at zero hid 840 of the raycaster's 930
  # divides a frame, since its hot ones all sit inside world[…].
  #
  # The READ those brackets do has a price of its own — it is not the single load it was
  # once taken for — so the two programs differ by exactly that and nothing else.
  def test_the_math_inside_an_index_costs_what_it_costs_outside
    outside = program do
      screen :bitmap
      table :nums, (0...64).to_a
      i = var :i, 3
      out = var :out, 0
      game_loop { out.set(((i / 5) * 8) + (i / 3)) }
    end
    inside = program do
      screen :bitmap
      t = table :nums, (0...64).to_a
      i = var :i, 3
      out = var :out, 0
      game_loop { out.set t[((i / 5) * 8) + (i / 3)] }
    end

    # 64 numbers long, so a read of it wraps an out-of-range index rather than clamping it.
    near Cost.new.frame_cost(outside) + WEIGHTS[:table_read], Cost.new.frame_cost(inside)
    assert_operator Cost.new.frame_cost(inside), :>=, 2 * WEIGHTS[:op_div_const],
                    "two divides in that index, and neither of them is free"
  end

  # clamp's bounds may be worked out as the game runs (x.clamp 0, limit). When they are,
  # they're evaluated every time it runs, so they cost what they'd cost anywhere else.
  def test_a_bound_the_game_works_out_is_priced
    fixed = program do
      screen :bitmap
      x = var :x, 0
      var :limit, 100
      game_loop { x.clamp 0, 100 }
    end
    computed = program do
      screen :bitmap
      x = var :x, 0
      limit = var :limit, 100
      game_loop { x.clamp 0, limit / 5 }
    end

    near WEIGHTS[:op_div_const] + var_reads, Cost.new.frame_cost(computed) - Cost.new.frame_cost(fixed),
         "the divide, and reading the bound it divides"
  end

  # Same for a drawing op's position: blit :ship, (col * W), y does the multiply before
  # it draws a single pixel.
  def test_a_drawing_position_the_game_works_out_is_priced
    ship = ->(x) { Build.blit(:ship, x, Build.int(0)) }
    prog = lambda do |x|
      Build.program(
        Build.screen(:bitmap),
        Build.bitmap(:ship, width: 8, height: 4, pixels: Array.new(32, 0).pack("v*"), transparent: nil),
        Build.loop_(Build.wait_vblank, ship.call(x)),
      )
    end
    plain = prog.call(Build.var_ref(:col))
    scaled = prog.call(Build.binop(:*, Build.var_ref(:col), Build.int(8)))

    # `* 8` is the cheapest operator there is — and it is still charged, which is the point.
    near WEIGHTS[:op_mul_pow2], Cost.new.frame_cost(scaled) - Cost.new.frame_cost(plain)
  end

  # Stamping a tiled background is one upload, priced per map cell. A background is a
  # boot-time statement, so the model only reaches it in a program with no game loop —
  # a narrow path, and the only one that prices it at all.
  def test_a_tiled_background_is_priced_by_its_map
    stamped = lambda do |rows|
      program do
        screen :tiled
        image(:brick, "#" => :red) { "########\n" * 8 }
        tiles :walls, "#" => :brick
        background :level, tiles: :walls, map: Array.new(rows, "####")
        halt
      end
    end

    extra = Cost.new.frame_cost(stamped.call(6)) - Cost.new.frame_cost(stamped.call(3))
    near (3 * 4) * WEIGHTS[:dma_pixel], extra, "three more rows of four cells, in the one upload"
  end

  # Every slot type the schema uses, so a node of any kind can be built here.
  SLOT_FILLER = { name: :default, text: "", int: 1, option: :x, list: [],

                  flag: false, color: 0 }.freeze

  # Drift guard, read off the schema rather than a hand-kept list: build one node of
  # every kind that has value slots, put a divide in each of those slots, and check the
  # estimate charges for it. A kind added later that can hold arithmetic cannot go
  # unpriced without failing here.
  def test_every_kind_prices_the_operands_it_holds
    unpriced = RubyGBA::IR::Fields.by_kind.filter_map do |kind, slots|
      slots_holding_values = slots.select { |_, type| type == :value }.keys
      next if slots_holding_values.empty?
      next if category_of(kind) == :control # loop/if/case are priced in #build, not #op_cost

      kind unless prices_its_operands?(kind, slots, slots_holding_values.length)
    end

    assert_empty unpriced,
                 "these kinds charge nothing for the arithmetic in their value slots — the op's own " \
                 "cost belongs in own_op_cost/own_cost, and what it holds is priced by operand_cost"
  end

  # One node of the given kind, every value slot holding a divide, priced inside a loop.
  # A value node needs a statement to live in, and here that is a `set`, which costs an
  # assignment of its own.
  def prices_its_operands?(kind, slots, divides)
    attrs = slots.to_h do |slot, type|
      [slot, type == :value ? Build.binop(:/, Build.var_ref(:a), Build.var_ref(:b)) : SLOT_FILLER[type]]
    end
    node = RubyGBA::IR::Nodes.build(kind, **attrs)
    statement = value?(kind) ? Build.set(:out, node) : node
    prog = Build.program(Build.screen(:bitmap), Build.loop_(statement))

    charged = Cost.new.frame_cost(prog) - (value?(kind) ? WEIGHTS[:op_assign] : 0)
    charged >= (divides * WEIGHTS[:op_div]) - 1e-9
  end

  def value?(kind) = category_of(kind) == :value

  def category_of(kind) = RubyGBA::IR::Nodes.by_kind.fetch(kind).category

  # Weights are configurable (Postgres-GUC style): a dev can tune them or weight an
  # op up to discourage it. Doubling the DMA weights doubles a DMA-fill's cost.
  def test_weights_are_configurable
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end
    base = Cost.new.frame_cost(prog)
    doubled = Cost.new(plot_run_pixel: WEIGHTS[:plot_run_pixel] * 2).frame_cost(prog) # fill_rect writes per pixel
    near 2 * base, doubled
  end

  # --- what the build counted, against what a weight says (see Pricing#counted) ---

  def built(&block)
    RubyGBA.build("CNT", code: "BCNT", maker: "01", err: StringIO.new, &block)
  end

  # A straight run of instructions is priced by counting what the lowering emitted, so the
  # weight that used to stand for the same instructions no longer decides anything. This is
  # the claim the whole change rests on, and the shape of the test is: move the weight a
  # long way and watch the answer not move.
  def test_a_straight_run_is_priced_by_counting_and_not_by_its_weight
    rom = built do
      screen :bitmap
      y = var :y, 0
      game_loop { 50.times { y.add 1 } }
    end

    near rom.cost_model.steady_cost(rom.source_program),
         rom.cost_model(op_step: WEIGHTS[:op_step] * 5).steady_cost(rom.source_program)
  end

  # ...and the rate is what decides it instead.
  def test_the_rate_is_what_a_counted_statement_turns_on
    rom = built do
      screen :bitmap
      y = var :y, 0
      game_loop { 50.times { y.add 1 } }
    end

    base = rom.cost_model.steady_cost(rom.source_program) - frame_boundary
    dearer = rom.cost_model(instruction: WEIGHTS[:instruction] * 2)
                .steady_cost(rom.source_program) - frame_boundary

    near 2 * base, dearer
  end

  # A comparison jumps over one of its two answers, so what was emitted is not what a frame
  # runs and the count is not the price. Its measured weight still decides.
  def test_a_comparison_keeps_its_measured_weight
    rom = built do
      screen :bitmap
      x = var :x, 3
      y = var :y, 0
      game_loop { 50.times { (x > 3).then { y.set 1 } } }
    end

    dearer = rom.cost_model(op_compare: WEIGHTS[:op_compare] * 2).steady_cost(rom.source_program)

    assert_operator dearer, :>, rom.cost_model.steady_cost(rom.source_program) * 1.2,
                    "a comparison is not priced by counting, so its weight has to still matter"
  end

  # WHOLE STATEMENT OR NONE OF IT. A weight was measured with an operand in front of it and
  # pays for that operand, which is why a plain read and a number written in the program are
  # priced at nothing. Count those on top of a weighted statement and they are charged
  # twice — a fifth over, on examples/maze.rb, which is how this was found.
  #
  # A moving rectangle is drawn by a loop, so it keeps its measured weights whatever the
  # rate is; the row it is drawn on is a variable, and the whole frame has to come to the
  # same either way.
  def test_the_operands_of_a_weighted_statement_stay_free
    rom = built do
      screen :bitmap, tear_free: true
      y = var :y, 0
      game_loop { draw_rect_at 40, y, 40, 20, :red }
    end
    program = rom.source_program

    near rom.cost_model(instruction: 0.0).steady_cost(program), rom.cost_model.steady_cost(program)
  end

  # NOTHING EMITTED IS NOT THE SAME AS COSTING NOTHING. A sprite's per-frame repaint passes
  # through the lowering where it is declared and emits none of what it costs — the drawing
  # is somewhere else entirely. Read as a count of nought it would take the whole of an
  # animated sprite's frame with it, which is most of what examples/animate.rb does.
  def test_a_statement_whose_work_is_emitted_elsewhere_keeps_its_weight
    rom = built do
      screen :bitmap
      image(:a, "." => :transparent, "#" => :red) { "##\n#." }
      image(:b, "." => :transparent, "#" => :blue) { ".#\n##" }
      sprite :s, at: [10, 10], frames: %i[a b], rate: 2
      game_loop { }
    end
    program = rom.source_program

    counted = rom.cost_model.steady_cost(program)
    weighted = rom.cost_model(instruction: 0.0).steady_cost(program)

    # Not to the last decimal — the sprite's own bookkeeping around the draw IS a straight
    # run and is counted — but the draw itself has to be there either way, and it is most of
    # both numbers.
    assert_in_delta weighted, counted, weighted * 0.02
    assert_operator counted, :>, frame_boundary * 1.5, "drawing the sprite has to cost something"
  end

  # A program nobody built has no counts to read, so it is priced the older way — which is
  # what keeps the model able to answer "what would this cost" before there is a cartridge.
  def test_a_program_with_no_build_behind_it_is_priced_by_the_weights
    prog = program do
      screen :bitmap
      n = var :n, 0
      game_loop { 50.times { n.add 1 } }
    end

    near frame_boundary + (50 * WEIGHTS[:op_step]), Cost.new.frame_cost(prog)
  end

  # Reading a button is not the free load it was priced as. The console hands back all ten
  # buttons at once, so asking about ONE means masking its bit out and turning the flag that
  # leaves into a 1 or a 0 — several times what reading a variable costs, and the whole of a
  # frame in a game that does nothing but steer.
  def test_reading_a_button_is_not_free
    bare = program do
      screen :bitmap
      game_loop {}
    end
    down = program do
      screen :bitmap
      game_loop { held(:a).then {} }
    end

    near frame_boundary, Cost.new.frame_cost(bare)
    near frame_boundary + button_down, Cost.new.frame_cost(down)
  end

  # ...and the latch behind `pressed`. Once a frame, this frame's buttons become last
  # frame's and the console's are read afresh, so every press test in the frame answers
  # about the same frame. It is paid ONCE however many presses a game reads, and not at all
  # by a game that only asks whether a button is down.
  def test_the_button_latch_is_paid_once_a_frame_and_only_where_a_press_is_read
    down = program do
      screen :bitmap
      game_loop { held(:a).then {} }
    end
    one = program do
      screen :bitmap
      game_loop { pressed(:a).then {} }
    end
    two = program do
      screen :bitmap
      game_loop do
        pressed(:a).then {}
        pressed(:b).then {}
      end
    end

    near frame_boundary + button_down, Cost.new.frame_cost(down)
    near frame_boundary + button_latch + button_press, Cost.new.frame_cost(one)
    near frame_boundary + button_latch + (2 * button_press), Cost.new.frame_cost(two)
  end

  # The latch belongs to the frame's BOUNDARY and not to the test, so a press the frame
  # never reaches still makes the boundary latch. The backend decides that — it emits the
  # latch for a program that reads a press anywhere — and the model asks it rather than
  # restating the rule, so this is the two agreeing.
  def test_a_press_the_frame_never_reads_still_costs_the_latch
    prog = program do
      screen :bitmap
      func(:never_called) { pressed(:a).then { set :n, 1 } }
      game_loop {}
    end

    near frame_boundary + button_latch, Cost.new.frame_cost(prog)
  end
end
