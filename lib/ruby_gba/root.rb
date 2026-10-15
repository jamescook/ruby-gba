# frozen_string_literal: true

require "pathname"

module RubyGBA
  # The folder the library was loaded from, as Rails.root is an application's.
  ROOT = Ractor.make_shareable(Pathname.new(__dir__).parent.parent)

  def self.root = ROOT
end
