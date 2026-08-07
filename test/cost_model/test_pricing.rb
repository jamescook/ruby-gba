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

  # fill_rect is a CPU per-pixel loop; dma_fill_rect is a per-row DMA. The split prices
  # them apart — the same rectangle costs far more filled by the CPU than by DMA.
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
    near(w * h * WEIGHTS[:plot_pixel], Cost.new.frame_cost(cpu))
    near((h * WEIGHTS[:dma_setup]) + (w * h * WEIGHTS[:dma_pixel]), Cost.new.frame_cost(dma))
    assert_operator Cost.new.frame_cost(cpu), :>, Cost.new.frame_cost(dma), "CPU plotting is dearer than a DMA fill"
  end

  # A blit costs its image's footprint (width x height), looked up from the bitmap
  # definition — so a game's sprites weigh in the estimate, not silently as zero.
  def test_blit_costs_its_image_footprint
    prog = Build.program(
      Build.screen(:bitmap),
      Build.bitmap(:ship, width: 8, height: 4, pixels: Array.new(32, 0).pack("v*"), transparent: nil),
      Build.loop_(Build.wait_vblank, Build.blit(:ship, Build.int(0), Build.int(0))),
    )
    near dma_rows(8, 4), Cost.new.steady_cost(prog) # opaque: one DMA per row
    near dma_rows(8, 4), Cost.new.frame_cost(prog)
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

  # The cost model reads the node's font, so a denser/bigger font costs more: the
  # same digits drawn in the compact :tiny font plot fewer pixels than in :default.
  def test_the_cost_of_text_follows_the_node_font
    default = program { screen(:bitmap); draw_text("42", 0, 0, :white); halt }
    tiny    = program { screen(:bitmap); draw_text("42", 0, 0, :white, font: :tiny); halt }
    near text_cost("42", :default), Cost.new.frame_cost(default)
    near text_cost("42", :tiny), Cost.new.frame_cost(tiny)
    assert_operator Cost.new.frame_cost(tiny), :<, Cost.new.frame_cost(default), "tiny should cost less"
  end

  # A draw_number column is a single draw_digit node worth one glyph — there's no
  # ten-way fan-out in the tree to discount, so a column's full and steady costs are
  # both just one glyph (a 3-digit score is ~3 glyphs, not 30).
  def test_draw_number_column_costs_one_glyph
    prog = program do
      screen :bitmap
      var :score, 0
      game_loop do
        draw_number :score, 8, 8, :white, digits: 1 # one column -> one draw_digit
      end
    end
    # digits:1 draws exactly one glyph — plus the cheap arithmetic to pull the digit
    # out of the number. So the cost is one glyph's worth and change, never a phantom
    # fan-out to more columns (which would be two glyphs or more).
    assert_operator Cost.new.steady_cost(prog), :>=, digit_cost
    assert_operator Cost.new.steady_cost(prog), :<, 2 * digit_cost
    assert_operator Cost.new.frame_cost(prog), :>=, digit_cost
    assert_operator Cost.new.frame_cost(prog), :<, 2 * digit_cost
  end

  # --- tiled-mode per-frame upkeep is no longer free (gba-86vh) ---

  # Presenting sprites costs one position rewrite per sprite (the display composites
  # them for free, but moving them each frame is real CPU work).
  def test_present_objects_costs_one_update_per_sprite
    prog = Build.program(
      Build.screen(:tiled),
      Build.loop_(Build.wait_vblank, Build.present_objects(%i[hero ghost coin])),
    )
    near 3 * WEIGHTS[:obj_write], Cost.new.steady_cost(prog)
  end

  # Scrolling a background costs its two scroll-register writes; constant offsets are
  # free to evaluate.
  def test_scroll_background_costs_its_scroll_writes
    prog = Build.program(
      Build.screen(:tiled),
      Build.loop_(Build.wait_vblank, Build.scroll_background(:world, x: Build.int(4), y: Build.int(0))),
    )
    near WEIGHTS[:scroll_write], Cost.new.steady_cost(prog)
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
    near WEIGHTS[:camera_move], Cost.new.steady_cost(prog)

    fading = Build.program(
      Build.screen(:bitmap),
      Build.loop_(Build.wait_vblank, Build.fade(toward: :black, amount: Build.int(50))),
    )
    near WEIGHTS[:fade_set], Cost.new.steady_cost(fading)
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
    near WEIGHTS[:fade_set] + WEIGHTS[:op_mul] + WEIGHTS[:op_div_const], Cost.new.steady_cost(live)
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
    near WEIGHTS[:op_step], Cost.new.steady_cost(ordinary)
    near WEIGHTS[:op_step] + WEIGHTS[:save_write], Cost.new.steady_cost(saved)
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
    near WEIGHTS[:camera_move] + WEIGHTS[:fade_set], Cost.new.steady_drawing_cost(prog)
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
  def test_a_divide_by_a_power_of_two_is_priced_as_a_plain_step
    adder = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x + 1) }
    end
    halver = program do
      screen :bitmap
      x = var :x, 100
      game_loop { x.set(x / 256) }
    end

    near Cost.new.steady_cost(adder), Cost.new.steady_cost(halver)
  end

  def test_multiplying_and_wrapping_by_a_power_of_two_are_priced_as_plain_steps
    [->(x) { x * 64 }, ->(x) { x % 64 }].each do |cheap|
      plain = program do
        screen :bitmap
        x = var :x, 100
        game_loop { x.set(x + 1) }
      end
      shifted = program do
        screen :bitmap
        x = var :x, 100
        game_loop { x.set(cheap.call(x)) }
      end

      near Cost.new.steady_cost(plain), Cost.new.steady_cost(shifted)
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
    c_one = Cost.new.steady_cost(one)
    c_ten = Cost.new.steady_cost(ten)

    assert_operator c_one, :>, 0, "a compute loop is not free"
    near c_one * 10, c_ten, "ten iterations cost about ten times one"
  end

  # ---- operands are priced wherever they are written ----

  # A read like t[i] is a single load and free, but the arithmetic that works out i is
  # arithmetic like any other. The brackets must make no difference: pricing an index at
  # zero hid 840 of the raycaster's 930 divides a frame, since its hot ones all sit
  # inside world[…].
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

    near Cost.new.frame_cost(outside), Cost.new.frame_cost(inside)
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

    near WEIGHTS[:op_div_const], Cost.new.frame_cost(computed) - Cost.new.frame_cost(fixed)
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

    near WEIGHTS[:op_mul], Cost.new.frame_cost(scaled) - Cost.new.frame_cost(plain)
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
    unpriced = RubyGBA::IR::Verifier::SLOTS.filter_map do |kind, slots|
      slots_holding_values = slots.select { |_, type| type == :value }.keys
      next if slots_holding_values.empty?
      next if Node::CATEGORY[kind] == :control # loop/if/case are priced in #build, not #op_cost

      kind unless prices_its_operands?(kind, slots, slots_holding_values.length)
    end

    assert_empty unpriced,
                 "these kinds charge nothing for the arithmetic in their value slots — the op's own " \
                 "cost belongs in own_op_cost/own_cost, and what it holds is priced by operand_cost"
  end

  # One node of the given kind, every value slot holding a divide, priced inside a loop.
  # A value node needs a statement to live in, which costs one step of its own.
  def prices_its_operands?(kind, slots, divides)
    attrs = slots.to_h do |slot, type|
      [slot, type == :value ? Build.binop(:/, Build.var_ref(:a), Build.var_ref(:b)) : SLOT_FILLER[type]]
    end
    node = Node.new(kind, **attrs)
    statement = value?(kind) ? Build.set(:out, node) : node
    prog = Build.program(Build.screen(:bitmap), Build.loop_(statement))

    charged = Cost.new.frame_cost(prog) - (value?(kind) ? WEIGHTS[:op_step] : 0)
    charged >= (divides * WEIGHTS[:op_div]) - 1e-9
  end

  def value?(kind) = Node::CATEGORY[kind] == :value

  # Weights are configurable (Postgres-GUC style): a dev can tune them or weight an
  # op up to discourage it. Doubling the DMA weights doubles a DMA-fill's cost.
  def test_weights_are_configurable
    prog = program do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end
    base = Cost.new.frame_cost(prog)
    doubled = Cost.new(plot_pixel: WEIGHTS[:plot_pixel] * 2).frame_cost(prog) # fill_rect plots per pixel
    near 2 * base, doubled
  end
end
