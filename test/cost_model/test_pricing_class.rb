# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Pricing (lib/ruby_gba/ir/cost_model/pricing.rb) as a standalone class: constructed
# directly with its own weights/catalogue/walker, independent of CostModel and the
# black-box tests that exercise it only through #analyze/#steady_cost.
class TestPricingClass < CostModelTest
  Pricing = RubyGBA::IR::CostModel::Pricing
  Catalogue = RubyGBA::IR::CostModel::Catalogue
  Walker = RubyGBA::IR::CostModel::Walker

  def empty_catalogue
    Catalogue.new(modes: nil, funcs: {}, capacities: {}, declared: {}, list_lengths: {},
                  table_lengths: {}, songs: {}, bitmaps: {}, objects: {}, backing: {},
                  sees_through: false)
  end

  def test_prices_an_op_from_its_own_weights_with_no_costmodel_involved
    catalogue = empty_catalogue
    walker = Walker.new(catalogue: catalogue, weights: WEIGHTS, fast_routines: [], fast_frame: false,
                        fast_interrupts: false, loop_shapes: {})
    pricing = Pricing.new(weights: WEIGHTS, catalogue: catalogue, walker: walker, palette_entries: {})
    walker.pricing = pricing

    node = Build.clear_screen(:black)

    near WEIGHTS[:dma_cpu_start] + WEIGHTS[:dma_engine_start] + (240 * 160 * WEIGHTS[:dma_pixel]),
         pricing.op_cost(node)
  end

  def test_a_different_weights_table_changes_the_price
    catalogue = empty_catalogue
    walker = Walker.new(catalogue: catalogue, weights: WEIGHTS, fast_routines: [], fast_frame: false,
                        fast_interrupts: false, loop_shapes: {})
    custom = WEIGHTS.merge(dma_pixel: WEIGHTS[:dma_pixel] * 10)
    pricing = Pricing.new(weights: custom, catalogue: catalogue, walker: walker, palette_entries: {})
    walker.pricing = pricing

    node = Build.clear_screen(:black)
    assert_operator pricing.op_cost(node), :>, WEIGHTS[:dma_cpu_start] + WEIGHTS[:dma_engine_start] +
                                               (240 * 160 * WEIGHTS[:dma_pixel])
  end
end
