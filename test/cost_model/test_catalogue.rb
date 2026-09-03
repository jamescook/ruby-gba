# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# What Rollup#index settles once by walking the whole program, before any price is
# asked: every func/list/table/bitmap declaration, and whether any layer can be seen
# through (lib/ruby_gba/ir/cost_model/catalogue.rb). Exercised directly against a
# built program — independent of the black-box CostModel tests, which only prove the
# numbers that come out the other end.
class TestCatalogue < CostModelTest
  Catalogue = RubyGBA::IR::CostModel::Catalogue

  def test_catalogues_a_func_a_list_and_a_table
    prog = program do
      screen :bitmap
      func(:helper) { }
      call :helper
      list :body, capacity: 8, estimate: { usually: 4 }
      table :nums, [1, 2, 3, 4, 5]
      halt
    end

    catalogue = Catalogue.build(prog)

    assert catalogue.funcs.key?(:helper), "the declared func is catalogued by name"
    assert_equal 8, catalogue.capacities[:body]
    assert_equal 8, catalogue.declared[:body], "8 is already a power of two, so nothing was rounded up for it"
    assert_equal 4, catalogue.list_lengths[:body], "the usually: hint, not the capacity"
    assert_equal 5, catalogue.table_lengths[:nums]
  end

  # An image with a see-through color is drawn a pixel at a time, so the catalogue
  # counts what's actually lit rather than treating it as a solid rectangle.
  def test_catalogues_a_transparent_bitmaps_lit_pixels_and_rows
    prog = program do
      screen :bitmap
      image :spr, "." => :transparent, "#" => :red do
        <<~ART
          #.
          .#
        ART
      end
      halt
    end

    bmp = Catalogue.build(prog).bitmaps[:spr]

    assert_equal 2, bmp.width
    assert_equal 2, bmp.height
    assert bmp.transparent
    assert_equal 2, bmp.lit_pixels, "one lit pixel in each row"
    assert_equal 2, bmp.lit_rows, "both rows hold a lit pixel"
    assert_equal 2, bmp.column_rows, "each column's single lit cell is a one-row run"
  end

  def test_catalogues_whether_a_layer_can_be_seen_through
    seen_through = program do
      screen :tiled
      layers :bg, :fg
      layer(:fg, transparency: 40) { }
      halt
    end
    solid = program do
      screen :tiled
      layers :bg, :fg
      layer(:fg) { }
      halt
    end

    assert Catalogue.build(seen_through).sees_through_a_layer?
    refute Catalogue.build(solid).sees_through_a_layer?
  end

  # Catalogue.build is called once per #analyze/#steady_cost — the numbers it feeds
  # Pricing/Verdicts/Tree don't move whether or not you touch #index yourself.
  def test_is_the_same_data_a_full_analyze_uses
    prog = program do
      screen :bitmap
      list :body, capacity: 8, estimate: { usually: 4 }
      halt
    end

    assert_equal 8, Catalogue.build(prog).capacities[:body]
    Cost.new.analyze(prog) # exercises the exact same path through Rollup#index
  end
end
