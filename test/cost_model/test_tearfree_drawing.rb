# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Drawing costs what the screen it is on makes it cost.
#
# The tear-free screen holds a pixel as one BYTE — a number picking a color out of a
# table — where the direct-color screen holds the color itself in two. Video memory
# refuses to write a lone byte there, so the smallest write covers two side-by-side
# pixels, and every shape the screen draws is built out of pairs written straight out,
# single pixels read and spliced back, and runs handed to the block-fill engine.
#
# None of that resembles the direct-color screen, so one price per verb cannot be right
# for both. It used to be: `fill_rect` was priced as a CPU loop over every pixel, which
# is what it is in direct color and nothing like what it is here — a full-width band was
# quoted at twenty times what the console measures, and the raycaster read as over budget
# while holding sixty frames a second.
#
# These assert the SHAPE of the answer (which of two things costs more, and why) rather
# than numbers that move when the weights are re-measured.
class TestTearFreeDrawing < CostModelTest
  def tear_free(&block)
    program do
      screen :bitmap, tear_free: true
      instance_eval(&block)
    end
  end

  def direct(&block)
    program do
      screen :bitmap
      instance_eval(&block)
    end
  end

  # --- a fixed rectangle: a block fill a row, not a pixel at a time ---

  # The heart of it. Filling in direct color really is a CPU loop over every pixel; on
  # the tear-free screen the same call hands each row to the block-fill engine, which is
  # a different order of work. Pricing both as the loop made ordinary tear-free drawing
  # read many times dearer than it is.
  def test_a_fixed_fill_is_not_priced_as_a_pixel_loop_on_the_tear_free_screen
    loops = direct { game_loop { fill_rect 8, 8, 40, 40, :red } }
    fills = tear_free { game_loop { fill_rect 8, 8, 40, 40, :red } }

    near frame_boundary + plot_rect(40, 40), Cost.new.steady_cost(loops)
    near frame_boundary + tearfree_fill(40, 40), Cost.new.steady_cost(fills)
    assert_operator Cost.new.steady_cost(fills) * 4, :<, Cost.new.steady_cost(loops),
                    "a block fill a row is a different order of work from a pixel at a time"
  end

  # `fill_rect` and `dma_fill_rect` are the same block fill on this screen — the DSL
  # keeps them apart because they differ in direct color, and here they do not.
  def test_the_two_fixed_fills_cost_the_same_on_the_tear_free_screen
    plain = tear_free { game_loop { fill_rect 8, 8, 40, 40, :red } }
    dma   = tear_free { game_loop { dma_fill_rect 8, 8, 40, 40, :red } }

    near Cost.new.steady_cost(dma), Cost.new.steady_cost(plain)
  end

  # A band spanning the whole screen width is one unbroken run of memory — the next row
  # starts exactly where the last one ended — so it goes in as ONE fill instead of one
  # per row. Which makes the WIDER band the cheaper one, and pricing per row hid that:
  # a sky and a floor were quoted at more than half a frame between them.
  def test_a_full_width_band_costs_less_than_a_narrower_one
    full   = tear_free { game_loop { dma_fill_rect 0, 0, 240, 80, :red } }
    narrow = tear_free { game_loop { dma_fill_rect 0, 0, 238, 80, :red } }

    assert_operator Cost.new.steady_cost(full), :<, Cost.new.steady_cost(narrow),
                    "the wider band is one fill; the narrower one is eighty"
  end

  # Only when nothing is clipped off it: a band hanging past the bottom of the screen
  # has rows to skip, so it goes back to one fill a row.
  def test_a_band_that_runs_off_the_screen_is_filled_a_row_at_a_time
    on   = tear_free { game_loop { dma_fill_rect 0, 80, 240, 80, :red } }
    over = tear_free { game_loop { dma_fill_rect 0, 100, 240, 80, :red } } # 20 rows off the bottom

    assert_operator Cost.new.steady_cost(over), :>, Cost.new.steady_cost(on)
  end

  # A rectangle starting on an ODD column has, on every row, a first and last pixel
  # sharing their pair with a pixel outside it — so those two are read and spliced back
  # one at a time while the engine fills the even middle. Each is the same read-splice-write
  # a moving row's near end is, and the two pixels they take out of the middle are two the
  # engine no longer moves.
  def test_an_odd_column_costs_two_spliced_pixels_a_row
    even = tear_free { game_loop { dma_fill_rect 8, 8, 40, 40, :red } }
    odd  = tear_free { game_loop { dma_fill_rect 9, 8, 40, 40, :red } }

    near 40 * ((2 * WEIGHTS[:tearfree_edge_near]) - (2 * WEIGHTS[:tearfree_fill_pixel])),
         Cost.new.steady_cost(odd) - Cost.new.steady_cost(even)
  end

  # --- a moving rectangle: pairs written straight out ---

  # THE ONE THAT LOOKS WRONG AND IS NOT. A two-pixel column is one write a row — the
  # pair goes in whole. A one-pixel column has to read the pair it shares with the
  # pixel beside it, change half, and write it back. So the wider column is the cheaper
  # one, and two of the narrow ones cost several times one of the wide.
  def test_a_two_pixel_column_costs_less_than_two_one_pixel_columns
    wide = tear_free { game_loop { draw_rect_at 40, 0, 2, 100, :red } }
    thin = tear_free { game_loop { draw_rect_at(40, 0, 1, 100, :red); draw_rect_at(42, 0, 1, 100, :red) } }

    assert_operator Cost.new.steady_cost(wide), :<, Cost.new.steady_cost(thin),
                    "one pair written whole beats two pixels each spliced into one"
  end

  # A narrow run is written out pair by pair; a wide one is worth starting the block-fill
  # engine for. So the price per row climbs gently with width and then steps up at the
  # width where the engine takes over — past twenty-four pixels, which is where the console
  # says the two cross on speed and on code size alike.
  #
  # x is `(k * 8) + 2` rather than a written-in number: every edge settled while building
  # sends `draw_rect_at` down the exact fixed-rect path `fill_rect` takes instead (nothing
  # left to clip), which is not this shape at all. The expression proves even the same way
  # a grid layout's column would, and it is the SAME shape at every width tested, so its
  # own cost is a flat amount that cancels out of every difference below.
  def test_a_narrow_run_is_written_out_and_a_wide_one_is_block_filled
    per_row = lambda do |w|
      prog = tear_free do
        k = var :k, 5
        game_loop { draw_rect_at (k * 8) + 2, 0, w, 100, :red }
      end
      Cost.new.steady_cost(prog) / 100
    end

    assert_in_delta WEIGHTS[:tearfree_pair], per_row.call(4) - per_row.call(2), 1e-6,
                    "two more pixels written straight out is one more pair"
    assert_in_delta 4 * WEIGHTS[:tearfree_pair], per_row.call(24) - per_row.call(16), 1e-6,
                    "and a row of twenty-four is still written out, eight pixels being four pairs"
    assert_operator per_row.call(26) - per_row.call(24), :>, 8 * WEIGHTS[:tearfree_pair],
                    "past there the engine is started instead, which costs more to begin"
  end

  # A moving rectangle STEPS its destination along; a fixed one rebuilds it every row. So a
  # wide moving row is no dearer than a fixed one — measured, the two are within a
  # twentieth of each other. The model used to charge the moving one the step AND the fixed
  # one's whole setup, which is the address work twice, and made it read a third dearer
  # than the console says it is.
  #
  # `x` has to be a PROVABLY EVEN expression here, not a written-in number: a `draw_rect_at`
  # whose every edge is settled while building takes the exact fixed-rect shape `fill_rect`
  # does (nothing is left for the console to clip), so a literal x would compare that shape
  # against itself and prove nothing. `(k * 8) + 2` keeps the row itself splice-free — an
  # unprovable column would also pay for two spliced ends on top, which is a genuinely
  # different, dearer shape and not what this is asking about.
  def test_a_wide_moving_rectangle_costs_about_what_a_fixed_one_does
    moving = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 20, 40, 40, :red } }
    fixed  = tear_free { game_loop { fill_rect 40, 20, 40, 40, :red } }

    ratio = Cost.new.steady_cost(moving) / Cost.new.steady_cost(fixed)
    assert_operator ratio, :<, 1.05, "a moving row does not also pay to rebuild what it steps along"
    assert_operator ratio, :>, 0.95, "but it still starts the same engine, so it is not much cheaper"
  end

  # An end is the same work whatever the middle beside it does — the emitter splices it
  # with the same instructions either way — so it is the same weight either way. It used
  # to have a second weight of its own for wide rows, worth a third more, which was really
  # the row's unaccounted address work hiding inside an averaged figure.
  #
  # `(k * 8) + 2` / `+ 1` rather than written-in numbers, for the same reason every test
  # in this section reaches for that shape now: a literal x sends `draw_rect_at` down the
  # fixed-rect path instead. Both sides read the same variable through the same multiply,
  # differing only in which constant flips the proof even or odd, so that cost cancels.
  def test_a_row_splices_its_ends_at_the_same_price_whatever_its_middle_does
    even = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 20, 40, 40, :red } } # a middle for the engine
    odd  = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 1, 20, 40, 40, :red } }

    # An odd column splices both ends and so has three parts where the even row had one;
    # the two spliced pixels also leave the run the engine moves.
    near 40 * ((2 * WEIGHTS[:tearfree_part]) + WEIGHTS[:tearfree_edge_near] +
               WEIGHTS[:tearfree_edge] - (2 * WEIGHTS[:tearfree_fill_pixel])),
         Cost.new.steady_cost(odd) - Cost.new.steady_cost(even)
  end

  # The two ends are NOT alike, and that is not a rounding difference. The near one has to
  # clear a bit to name the pair its pixel sits in; the far one is already on a pair
  # boundary. A rectangle one pixel wide is exactly one end and nothing else, so the two
  # can be told apart by which column it stands in.
  #
  # `(k * 8) + 2` / `+ 1` again, so the column stays provably even or odd without a
  # written-in x turning this into the fixed-rect shape instead.
  def test_the_near_end_of_a_row_costs_more_than_the_far_end
    far  = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 0, 1, 100, :red } } # even: only a far end
    near_end = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 1, 0, 1, 100, :red } } # odd: only a near end

    near 100 * (WEIGHTS[:tearfree_edge_near] - WEIGHTS[:tearfree_edge]),
         Cost.new.steady_cost(near_end) - Cost.new.steady_cost(far)
    assert_operator WEIGHTS[:tearfree_edge_near], :>, WEIGHTS[:tearfree_edge],
                    "the near end has a bit to clear that the far end does not"
  end

  # A row is built out of PARTS, and only the first one starts where the row itself does —
  # each one after it has to work out where in memory it goes. Charging that once a row
  # however many parts it had is what made a rectangle at an odd column read at seven
  # tenths of its cost: three parts were paying for one.
  #
  # `(k * 8) + 2` keeps x even and off the fixed-rect path in both calls, so only the
  # width — and so the row's parts — changes between them.
  def test_each_part_of_a_row_after_the_first_pays_to_be_reached
    one  = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 0, 2, 100, :red } } # a middle, and that is all
    two  = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 0, 3, 100, :red } } # a middle and a far end

    # The extra pixel is a spliced far end, and reaching it is a part of its own.
    near 100 * (WEIGHTS[:tearfree_part] + WEIGHTS[:tearfree_edge]),
         Cost.new.steady_cost(two) - Cost.new.steady_cost(one)
  end

  # The column decides whether a row has pixels to splice, and a column settled while
  # building is known exactly. When the game works it out, both columns are possible and
  # only one of them is emitted — so it is priced at the dearer, the same call the model
  # makes for a scene dispatch, where only one branch runs a frame.
  #
  # "Settled while building" cannot mean a written-in number here — that takes the whole
  # rect down the fixed-rect path instead of this one — so `fixed` is `(k * 8) + 2`, an
  # expression IR::Parity still proves even without knowing what the game runs `k` out to.
  def test_a_column_the_game_works_out_is_priced_at_the_dearer_parity
    fixed  = tear_free { k = var :k, 5; game_loop { draw_rect_at (k * 8) + 2, 0, 8, 100, :red } } # an even column, proved
    moving = tear_free do
      x = var :x, 40
      game_loop { draw_rect_at x, 0, 8, 100, :red }
    end

    assert_operator Cost.new.steady_cost(moving), :>, Cost.new.steady_cost(fixed)
    # Two spliced ends taking the place of one of the pairs the even row wrote, and the
    # two extra parts they make of the row — minus what `fixed` spends proving its column
    # even (a multiply and an add) that `moving`'s bare variable read never does.
    near (100 * ((2 * WEIGHTS[:tearfree_part]) + WEIGHTS[:tearfree_edge_near] +
                WEIGHTS[:tearfree_edge] - WEIGHTS[:tearfree_pair])) -
         (WEIGHTS[:op_mul_pow2] + WEIGHTS[:op_plain]),
         Cost.new.steady_cost(moving) - Cost.new.steady_cost(fixed)
  end

  # ...but "the game works it out" is not the same as "nobody can tell". A game laying its
  # world out on a grid writes `cell * 8`, and eight times anything is even however the
  # game works `cell` out, so the cheaper row is the only one that can run. Charging the
  # dearer one there over-charges by three — and the backend emits one shape too, from the
  # same proof, so the two cannot disagree about which row was priced.
  #
  # The row this actually runs depends on the PARITY that gets proved, not on which sum
  # proved it. `cell * 6` proves even the same way `cell * 8` does (6 is even too), but by
  # a real multiply instead of a shift — a different arrival cost. So `grid_even` and
  # `alt_even` must land on the exact same even row once that one difference is told apart.
  def test_a_provable_column_is_priced_as_the_row_it_will_actually_run
    grid_even = tear_free do
      cell = var :cell, 5
      game_loop { draw_rect_at (cell * 8) + 2, 0, 8, 100, :red }
    end
    grid_odd = tear_free do
      cell = var :cell, 5
      game_loop { draw_rect_at (cell * 8) + 1, 0, 8, 100, :red }
    end
    alt_even = tear_free do
      cell = var :cell, 5
      game_loop { draw_rect_at (cell * 6) + 2, 0, 8, 100, :red }
    end

    # *8 is a shift; *6 is a real multiply — the only thing that may differ between them,
    # so it is the only correction it takes to land back on the same even row.
    near WEIGHTS[:op_mul] - WEIGHTS[:op_mul_pow2],
         Cost.new.steady_cost(alt_even) - Cost.new.steady_cost(grid_even)
    assert_operator Cost.new.steady_cost(grid_odd), :>, Cost.new.steady_cost(grid_even),
                    "and the odd one is still the dearer, which is the whole reason to ask"
  end

  # The refusal, which is the half that keeps this honest. Three times a number is even or
  # odd as that number is, so nothing is proved and the dearer row is charged again — even
  # though the column beside it, six times the same number, is proved even by the same
  # rule. The two take identical work to arrive at, so what separates them is one row shape.
  #
  # An estimate under what the game costs is the one failure the model exists to prevent,
  # so a near miss like this must fall back rather than guess.
  def test_a_column_with_no_provable_parity_is_still_charged_the_dearer_row
    proved = tear_free do
      cell = var :cell, 5
      game_loop { draw_rect_at (cell * 6) + 2, 0, 8, 100, :red }
    end
    refused = tear_free do
      cell = var :cell, 5
      game_loop { draw_rect_at (cell * 3) + 2, 0, 8, 100, :red }
    end

    # Two spliced ends taking the place of one of the pairs the even row wrote, and the
    # two extra parts they make of the row — the worst-case charge, in full.
    near 100 * ((2 * WEIGHTS[:tearfree_part]) + WEIGHTS[:tearfree_edge_near] +
                WEIGHTS[:tearfree_edge] - WEIGHTS[:tearfree_pair]),
         Cost.new.steady_cost(refused) - Cost.new.steady_cost(proved)
  end

  # --- pixels, text and the whole screen ---

  # A lone pixel is a read-modify-write here (it shares its sixteen bits with its
  # neighbour), where the direct screen just writes it. Priced the same, the tear-free
  # one was charged half what it costs.
  def test_a_lone_pixel_costs_more_on_the_tear_free_screen
    here  = tear_free { game_loop { pixel 10, 10, :red } }
    there = direct { game_loop { pixel 10, 10, :red } }

    near frame_boundary + WEIGHTS[:tearfree_pixel], Cost.new.steady_cost(here)
    near frame_boundary + WEIGHTS[:plot_pixel], Cost.new.steady_cost(there)
    assert_operator Cost.new.steady_cost(here), :>, Cost.new.steady_cost(there)
  end

  # A live digit walks the same glyph table on both screens, so what differs is only the
  # stamp — and stamping here means reading the pair a pixel shares with its neighbour,
  # changing half of it and writing it back, which is two and a half times a plain write.
  def test_a_live_digit_costs_more_on_the_tear_free_screen
    here  = tear_free { var :score, 0; game_loop { draw_number :score, 8, 8, :white, digits: 1 } }
    there = direct { var :score, 0; game_loop { draw_number :score, 8, 8, :white, digits: 1 } }

    assert_operator Cost.new.steady_cost(here), :>, Cost.new.steady_cost(there)
    # But not by a lot, because the walk over the box is the same work on both and it is
    # most of what a digit costs.
    assert_operator Cost.new.steady_cost(here), :<, 2 * Cost.new.steady_cost(there)
  end

  def test_text_is_priced_by_the_screen_it_is_drawn_on
    here  = tear_free { game_loop { draw_text "SCORE", 0, 80, :white } }
    there = direct { game_loop { draw_text "SCORE", 0, 80, :white } }

    lit = RubyGBA::Fonts.get(:default).text_pixels("SCORE")
    near frame_boundary + (lit * WEIGHTS[:tearfree_glyph]), Cost.new.steady_cost(here)
    near frame_boundary + (lit * WEIGHTS[:plot_run_pixel]), Cost.new.steady_cost(there)
  end

  # Clearing the screen is one block fill either way, but a pixel here is one byte where
  # a direct-color one is two — so the same transfer covers twice as many pixels and the
  # same picture is half the work.
  def test_clearing_the_tear_free_screen_is_half_the_work
    here  = tear_free { game_loop { clear_screen :black } }
    there = direct { game_loop { clear_screen :black } }

    near frame_boundary + tearfree_clear, Cost.new.steady_cost(here)
    near frame_boundary + dma_blob(240 * 160), Cost.new.steady_cost(there)
    # The clears themselves, since the frame's own boundary is the same on both screens and
    # would narrow the ratio this is about.
    assert_in_delta 2.0,
                    (Cost.new.steady_cost(there) - frame_boundary) /
                    (Cost.new.steady_cost(here) - frame_boundary), 0.01
  end

  # --- which screen, worked out per routine ---

  # A game can put a direct-color title in front of a tear-free play field, and the
  # SAME code costs different things in the two. The price follows the routine the walk
  # is inside, not the screen the program booted on.
  def test_the_same_drawing_is_priced_by_the_scene_it_is_in
    game = program do
      screen :bitmap # boots direct-color
      state = var :state, 0
      scene(:title) { fill_rect 8, 8, 40, 40, :red }
      scene(:play) do
        screen :bitmap, tear_free: true
        fill_rect 8, 8, 40, 40, :red
      end
      game_loop { case_var(state) { when_val 0, :title; when_val 1, :play } }
    end

    verdicts = Cost.new.scene_verdicts(game)
    title = verdicts.find { |s| s.name == "title" }
    play  = verdicts.find { |s| s.name == "play" }

    near plot_rect(40, 40), title.steady_cost
    near tearfree_fill(40, 40), play.steady_cost
  end

  # ...including a helper the scene calls, which draws on its caller's screen.
  def test_a_helper_draws_on_the_screen_of_the_scene_that_calls_it
    game = program do
      screen :bitmap, tear_free: true
      func(:paint) { fill_rect 8, 8, 40, 40, :red }
      game_loop { call :paint }
    end

    near frame_boundary + tearfree_fill(40, 40), Cost.new.steady_cost(game)
  end

  # --- a whole picture ---

  # A picture is a row copy a row on either screen, so its price has the same shape. What
  # differs is the pixels: a pixel is one byte here and two there, so a row moves half as
  # many units through the engine and the picture reads cheaper.
  def test_a_picture_costs_less_on_the_tear_free_screen_than_in_direct_colour
    art = ([("#" * 8)] * 4).join("\n")
    paged = tear_free do
      image(:block, "#" => :red) { art }
      game_loop { blit :block, 100, 40 }
    end
    plain = direct do
      image(:block, "#" => :red) { art }
      game_loop { blit :block, 100, 40 }
    end

    near frame_boundary + tearfree_blit(8, 4), Cost.new.steady_cost(paged)
    near frame_boundary + dma_rows_clipped(8, 4), Cost.new.steady_cost(plain)
    assert_operator Cost.new.steady_cost(paged), :<, Cost.new.steady_cost(plain),
                    "half the units through the engine has to cost less"
  end

  # A picture is not free, and the thing worth knowing about it is that a TALL one costs
  # more than a wide one of the same area: every row is its own clip and its own copy, and
  # only the pixels ride the engine.
  def test_a_tall_picture_costs_more_than_a_wide_one_of_the_same_area
    tall = tear_free do
      image(:tall, "#" => :red) { ([("#" * 4)] * 16).join("\n") }
      game_loop { blit :tall, 100, 40 }
    end
    wide = tear_free do
      image(:wide, "#" => :red) { ([("#" * 16)] * 4).join("\n") }
      game_loop { blit :wide, 100, 40 }
    end

    assert_operator Cost.new.steady_cost(wide), :<, Cost.new.steady_cost(tall),
                    "a row is a copy of its own, so more rows is more starts"
  end

  # --- an odd column, named as the reason ---

  # Sixty rectangles a frame laid out on a grid whose column the block works out.
  def grid(&column)
    tear_free { game_loop { repeat(60) { |i| draw_rect_at column.call(i), 20, 8, 8, :red } } }
  end

  # THE POINT. The tree prices an odd column exactly and never says the column is why, so a
  # game on `cell * 7` runs at half the speed it could, silently. The note names the line,
  # what it costs beside what an even column would, and the fix in the author's own words.
  def test_many_rectangles_at_an_odd_column_are_told_the_column_is_why
    out = reported(grid { |i| (i * 2) + 1 })

    assert_match(/60 rectangles a frame start at an odd column/, out)
    assert_match(/where an even column is ~[\d.]+/, out)
    assert_match(/use an even cell size/, out)
    assert_match(/test_tearfree_drawing\.rb:\d+/, out, "names the line")
    refute_match(/VRAM|16-bit|splic/i, out, "no hardware")
  end

  # A column nothing can prove is priced as the odd one, and the note says that is what
  # happened — the author who wrote `cell * 7` cannot know either.
  def test_a_column_the_build_cannot_prove_is_told_so
    out = reported(grid { |i| i * 7 })

    assert_match(/60 rectangles a frame start at a column the build cannot tell is even/, out)
    assert_match(/use an even cell size/, out)
  end

  # ...and an even grid is told nothing, because there is nothing to change.
  def test_an_even_grid_is_told_nothing
    refute_match(/even cell size/, reported(grid { |i| i * 8 }))
  end

  # A lone moving rectangle is a thing that moves, not a grid. It cannot have an even
  # column and must not be pushed toward one.
  def test_a_single_moving_rectangle_is_told_nothing
    lone = tear_free do
      x = var :x, 7
      game_loop { draw_rect_at x, 20, 8, 8, :red }
    end

    refute_match(/even cell size/, reported(lone))
  end

  # The direct-colour screen draws a pixel at a time and has no column to be odd at.
  def test_the_direct_colour_screen_is_told_nothing
    odd = direct { game_loop { repeat(60) { |i| draw_rect_at (i * 2) + 1, 20, 8, 8, :red } } }

    refute_match(/even cell size/, reported(odd))
  end
end
