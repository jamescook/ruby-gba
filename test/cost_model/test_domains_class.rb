# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Domains (lib/ruby_gba/ir/cost_model/domains.rb) as a standalone class.
# #weight_domain is a class method — it names no program and touches no pricing or
# verdict, so it needs no instance at all.
class TestDomainsClass < CostModelTest
  Domains = RubyGBA::IR::CostModel::Domains

  def test_weight_domain_needs_no_instance
    assert_empty Domains.weight_domain(:not_a_real_weight)
    refute_empty Domains.weight_domain(:op_step)
  end
end
