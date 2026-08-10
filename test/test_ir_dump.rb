# frozen_string_literal: true

require "test_helper"

require "prism"
require_relative "conformance_fixture"

# IR::Dump: turning a tree back into Ruby source that reconstructs it. Two kinds of
# proof, kept apart:
#
# - BEHAVIOR: dump a tree, eval the source, and check what came back — structurally
#   equal to the original, and (once lowered) byte-identical machine code. Asserted
#   against the conformance fixture, the kitchen-sink program that exercises (nearly)
#   every IR kind at once, so this doubles as coverage that Dump has no per-kind gap.
#
# - SHAPE: parse the source with Prism (the same parser Ruby itself uses) and check
#   specific, named nodes in the AST — which call is made, in what order its keyword
#   arguments appear — rather than pattern-matching the formatted text. A prose
#   description of the source can drift out of sync with a purely cosmetic
#   reformatting; an AST assertion can't be fooled by one.
class TestIRDump < Minitest::Test
  include RubyGBA::IR::Build

  Dump = RubyGBA::IR::Dump
  Nodes = RubyGBA::IR::Nodes

  # ---- behavior: dump, eval, compare ----

  def test_round_trips_the_conformance_fixture_structurally
    rebuilt = eval(Dump.source(ConformanceFixture.program)) # rubocop:disable Security/Eval

    assert_equal ConformanceFixture.program, rebuilt
  end

  def test_round_trips_to_byte_identical_lowered_code
    original_code = GBA.new.lower(ConformanceFixture.program)
    rebuilt = eval(Dump.source(ConformanceFixture.program)) # rubocop:disable Security/Eval
    rebuilt_code = GBA.new.lower(rebuilt)

    assert_equal original_code, rebuilt_code
  end

  def test_a_binary_string_operand_keeps_its_encoding
    node = Nodes.build(:data, name: :blob, bytes: "\x01\x02\xFF".b)
    rebuilt = eval(Dump.source(node)) # rubocop:disable Security/Eval

    assert_equal Encoding::ASCII_8BIT, rebuilt.bytes.encoding
    assert_equal node, rebuilt
  end

  # emit_class's whole file, evaluated in a scratch module (so the class it defines
  # lands there and not in the real, global RubyGBA namespace) and run for real —
  # the strongest available proof that what a user gets back is exactly what the
  # class claims to be: something that rebuilds the tree and lowers it, and nothing
  # more. $PROGRAM_NAME never equals the __FILE__ this eval is given, so the
  # trailing `ClassName.new.lower if $PROGRAM_NAME == __FILE__` correctly sits inert
  # here — proving that guard's OTHER half (it firing when run as a real script) is
  # test_cli.rb's job, over an actual `ruby` subprocess.
  def test_emit_class_runs_and_lowers_to_the_same_code_a_real_build_produces
    source = Dump.emit_class(ConformanceFixture.program, class_name: "FixtureIR",
                                                          fast_cartridge: true, fast_code: false)
    scratch = Module.new
    scratch.module_eval(source, "generated_ir.rb", 1)

    machine_code = scratch::FixtureIR.new.lower

    refute Object.const_defined?(:FixtureIR), "should not leak into the global namespace"
    assert_equal GBA.new(fast_cartridge: true, fast_code: false).lower(ConformanceFixture.program), machine_code
  end

  # A custom-registered font (`font :name do ... end`) lives in RubyGBA::Fonts, a
  # process-global registry OUTSIDE the IR tree — draw_text's `font:` operand only
  # names it by symbol. A fresh process running the emitted class never ran that
  # `font` DSL call, so without this the lookup fails there even though it worked
  # in the process that built the ROM. `fonts:` is how emit_class hands it back.
  def test_emit_class_carries_a_custom_font_the_tree_only_references_by_name
    font = RubyGBA::Font.new(glyphs: { "A" => [0b111, 0b101, 0b111] }, widths: { "A" => 3 }, height: 3)
    tree = program(draw_text("A", 0, 0, :white, font: :dump_test_font), halt)
    source = Dump.emit_class(tree, class_name: "LetteredIR", fast_cartridge: true, fast_code: true,
                                   fonts: { dump_test_font: font })

    scratch = Module.new
    scratch.module_eval(source, "generated_ir.rb", 1)

    assert scratch::LetteredIR.new.lower # doesn't raise looking up :dump_test_font
    assert_equal font.to_definition, RubyGBA::Fonts.get(:dump_test_font).to_definition
  end

  # ---- shape: parse with Prism, assert specific AST nodes ----

  def test_a_leaf_node_is_exactly_one_bare_build_call
    assert_equal "RubyGBA::IR::Nodes.build(:halt)", Dump.source(halt)
  end

  def test_a_kind_with_operands_and_children_orders_declared_operands_before_children
    node = func(:helper, set(:h, 1), wait_vblank)
    call = parse_call(Dump.source(node))

    assert_equal %i[RubyGBA IR Nodes], constant_path(call.receiver)
    assert_equal :build, call.name
    assert_equal :func, call.arguments.arguments.first.unescaped.to_sym

    keywords = call.arguments.arguments.last
    assert_instance_of Prism::KeywordHashNode, keywords
    # Func's own declared operands (name, then fast — see Nodes::Func) come first,
    # in that order; children (this func's two statements) come last, always.
    assert_equal %i[name fast children], keywords.elements.map { |assoc| assoc.key.unescaped.to_sym }
  end

  def test_children_are_each_their_own_build_call_in_source_order
    node = func(:helper, set(:h, 1), wait_vblank)
    call = parse_call(Dump.source(node))
    children = call.arguments.arguments.last.elements.last.value # the children: array

    assert_instance_of Prism::ArrayNode, children
    assert_equal %i[set wait_vblank], children.elements.map { |child| child.arguments.arguments.first.unescaped.to_sym }
  end

  def test_emit_class_source_is_syntactically_valid_and_defines_program_and_lower
    source = Dump.emit_class(ConformanceFixture.program, class_name: "FixtureIR",
                                                          fast_cartridge: true, fast_code: false)
    result = Prism.parse(source)
    assert result.success?, result.errors.map(&:message).join("\n")

    top_level = result.value.statements.body
    klass = top_level.find { |node| node.is_a?(Prism::ClassNode) }
    assert_equal :FixtureIR, klass.constant_path.name
    assert_equal %i[program lower], klass.body.body.select { |n| n.is_a?(Prism::DefNode) }.map(&:name)

    guard = top_level.find { |node| node.is_a?(Prism::IfNode) }
    assert_equal :"==", guard.predicate.name
    assert_instance_of Prism::GlobalVariableReadNode, guard.predicate.receiver
    assert_equal :$PROGRAM_NAME, guard.predicate.receiver.name
    assert_instance_of Prism::SourceFileNode, guard.predicate.arguments.arguments.first
  end

  private

  def parse_call(source)
    Prism.parse(source).value.statements.body.first
  end

  # A Prism::ConstantPathNode/ConstantReadNode chain (RubyGBA::IR::Nodes) as the
  # symbols it names, outermost first.
  def constant_path(node)
    return [node.name] if node.is_a?(Prism::ConstantReadNode)

    constant_path(node.parent) + [node.name]
  end
end
