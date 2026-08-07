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

    near plot_rect(40, 40), Cost.new.steady_cost(loops)
    near tearfree_fill(40, 40), Cost.new.steady_cost(fills)
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
  # one at a time while the engine fills the even middle.
  def test_an_odd_column_costs_two_spliced_pixels_a_row
    even = tear_free { game_loop { dma_fill_rect 8, 8, 40, 40, :red } }
    odd  = tear_free { game_loop { dma_fill_rect 9, 8, 40, 40, :red } }

    near 40 * 2 * WEIGHTS[:tearfree_edge], Cost.new.steady_cost(odd) - Cost.new.steady_cost(even)
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
  # width where the engine takes over.
  def test_a_narrow_run_is_written_out_and_a_wide_one_is_block_filled
    per_row = lambda do |w|
      prog = tear_free { game_loop { draw_rect_at 40, 0, w, 100, :red } }
      Cost.new.steady_cost(prog) / 100
    end

    assert_in_delta WEIGHTS[:tearfree_pair], per_row.call(4) - per_row.call(2), 1e-6,
                    "two more pixels written straight out is one more pair"
    assert_operator per_row.call(16) - per_row.call(8), :>, 8 * WEIGHTS[:tearfree_pair],
                    "past the narrow widths the engine is started instead, which costs more to begin"
  end

  # The column decides whether a row has pixels to splice, and a column settled while
  # building is known exactly. When the game works it out, both columns are possible and
  # only one of them is emitted — so it is priced at the dearer, the same call the model
  # makes for a scene dispatch, where only one branch runs a frame.
  def test_a_column_the_game_works_out_is_priced_at_the_dearer_parity
    fixed  = tear_free { game_loop { draw_rect_at 40, 0, 8, 100, :red } } # an even column, known
    moving = tear_free do
      x = var :x, 40
      game_loop { draw_rect_at x, 0, 8, 100, :red }
    end

    assert_operator Cost.new.steady_cost(moving), :>, Cost.new.steady_cost(fixed)
    # Two spliced ends, and they take the place of one of the pairs the even row wrote.
    near 100 * ((2 * WEIGHTS[:tearfree_edge]) - WEIGHTS[:tearfree_pair]),
         Cost.new.steady_cost(moving) - Cost.new.steady_cost(fixed)
  end

  # --- pixels, text and the whole screen ---

  # A lone pixel is a read-modify-write here (it shares its sixteen bits with its
  # neighbour), where the direct screen just writes it. Priced the same, the tear-free
  # one was charged half what it costs.
  def test_a_lone_pixel_costs_more_on_the_tear_free_screen
    here  = tear_free { game_loop { pixel 10, 10, :red } }
    there = direct { game_loop { pixel 10, 10, :red } }

    near WEIGHTS[:tearfree_pixel], Cost.new.steady_cost(here)
    near WEIGHTS[:plot_pixel], Cost.new.steady_cost(there)
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
    near lit * WEIGHTS[:tearfree_glyph], Cost.new.steady_cost(here)
    near lit * WEIGHTS[:plot_run_pixel], Cost.new.steady_cost(there)
  end

  # Clearing the screen is one block fill either way, but a pixel here is one byte where
  # a direct-color one is two — so the same transfer covers twice as many pixels and the
  # same picture is half the work.
  def test_clearing_the_tear_free_screen_is_half_the_work
    here  = tear_free { game_loop { clear_screen :black } }
    there = direct { game_loop { clear_screen :black } }

    near tearfree_clear, Cost.new.steady_cost(here)
    near dma_blob(240 * 160), Cost.new.steady_cost(there)
    assert_in_delta 2.0, Cost.new.steady_cost(there) / Cost.new.steady_cost(here), 0.01
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
    title = verdicts.find { |s| s[:name] == "title" }
    play  = verdicts.find { |s| s[:name] == "play" }

    near plot_rect(40, 40), title[:steady_cost]
    near tearfree_fill(40, 40), play[:steady_cost]
  end

  # ...including a helper the scene calls, which draws on its caller's screen.
  def test_a_helper_draws_on_the_screen_of_the_scene_that_calls_it
    game = program do
      screen :bitmap, tear_free: true
      func(:paint) { fill_rect 8, 8, 40, 40, :red }
      game_loop { call :paint }
    end

    near tearfree_fill(40, 40), Cost.new.steady_cost(game)
  end
end
