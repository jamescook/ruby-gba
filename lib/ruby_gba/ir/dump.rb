# frozen_string_literal: true

module RubyGBA
  module IR
    # Turn an IR tree back into Ruby SOURCE that reconstructs it — the inverse of
    # building one. `ruby-gba build --format=ir` uses this to hand back a runnable,
    # self-contained Ruby file holding a game's IR, for inspecting or bisecting the
    # compiler without a ROM in the way.
    #
    # GENERIC OVER EVERY KIND, on purpose: it reads whatever operands and children a
    # node actually carries (Node#attrs, Node#children) rather than knowing kind by
    # kind what those are, so a new IR feature needs nothing added here to be dumped
    # — the same reason {Node#to_h} and {Node#walk} need nothing either.
    #
    # It emits calls to {Nodes.build} (the plain, mechanical "kind symbol + operand
    # hash" constructor) rather than {Build}'s terser sugar (`Build.set`, `Build.if_`,
    # ...): the sugar methods wrap bare literals into value nodes, choose which
    # arguments become children versus operands, and generally don't map onto a
    # node's STORED shape one-for-one. `Nodes.build` does — an operand hash is
    # exactly what {Node#attrs} hands back — so it round-trips exactly, for any kind,
    # with one method.
    module Dump
      INDENT = "  "

      module_function

      # +node+'s Ruby source: a `Nodes.build(:kind, ...)` call, its nested value
      # operands and children spelled out the same way, recursively. Not indented on
      # its own first line (the caller is already mid-line); every line after the
      # first is indented +level+ steps deeper so nested children read as nested code.
      def source(node, level: 0)
        args = arg_list(node, level)
        return "RubyGBA::IR::Nodes.build(:#{node.kind})" if args.empty?

        "RubyGBA::IR::Nodes.build(:#{node.kind}, #{args.join(', ')})"
      end

      # This node's operands as `name: value` source fragments, plus a trailing
      # `children: [...]` when it has any — always last, so a reader sees a node's
      # own settings before its nested statements.
      def arg_list(node, level)
        args = node.attrs.map { |name, value| "#{name}: #{value_source(value, level)}" }
        args << children_source(node.children, level) unless node.children.empty?
        args
      end

      # `children: [` one child per line, each indented one step past +level+, `]`
      # back at +level+ — so the closing bracket lines up under the call that opened
      # it, however deep this node sits in the tree.
      def children_source(children, level)
        pad = INDENT * (level + 1)
        lines = children.map { |child| "#{pad}#{source(child, level: level + 1)}," }
        "children: [\n#{lines.join("\n")}\n#{INDENT * level}]"
      end

      # An operand's value: a nested node (recurse), a list (an Array — recurse over
      # its elements, which may themselves be nodes, numbers, or further nested
      # arrays — a table's numbers, a case's [value, target] pairs), a song's part, or
      # an author-time literal. Ruby's own #inspect already writes an
      # Integer/Symbol/String/bool back as valid source for anything else — that is the
      # whole reason the operand tags in {Verifier::TYPES} are plain Ruby types and not
      # a bespoke format.
      def value_source(value, level)
        case value
        when Node then source(value, level: level)
        when Array then "[#{value.map { |element| value_source(element, level) }.join(', ')}]"
        when String then string_source(value)
        when Music::Part then part_source(value)
        else value.inspect
        end
      end

      # A SONG'S PART, written back as the call that builds one. A record inspects as
      # `#<data ...>`, which describes it rather than rebuilding it — so the fields are
      # written out as keyword arguments instead. Only the ones that differ from the
      # defaults, since most parts leave most of them alone and a part that says nothing
      # but its notes should read that way in the dump too.
      def part_source(part)
        said = part.to_h.reject { |field, value| Music::Part::DEFAULTS[field] == value }
        args = said.map { |field, value| "#{field}: #{value_source(value, 0)}" }
        "RubyGBA::Music::Part.new(#{args.join(', ')})"
      end

      # #inspect alone loses a binary string's encoding — re-read as ordinary source,
      # the literal comes back tagged with the FILE's encoding, not the ASCII-8BIT a
      # sample or a packed asset was built with. Appending `.b` (the codebase's own
      # shorthand for that, e.g. in test/conformance_fixture.rb) restores it, so a
      # dumped `data`/`sample` round-trips byte-for-byte AND tag-for-tag.
      def string_source(value)
        value.encoding == Encoding::ASCII_8BIT ? "#{value.inspect}.b" : value.inspect
      end

      # A complete, standalone Ruby file: +program+ (a :program-kind node) wrapped in
      # a class named +class_name+ that can rebuild the tree and lower it to machine
      # code (RubyGBA::IR::Backends::GBA) — nothing more. No ROM header, no checksum,
      # no file written; that is `ruby-gba build`'s job, not this file's. Run directly
      # (`ruby` it), it lowers once and stops, so it is a plain way to reproduce
      # exactly what a build's codegen produced, e.g. to bisect a compiler change.
      #
      # +fonts+ is {name => Font}, any custom fonts (`font :name do ... end`) the
      # game registered — everything else a build needs lives in +program+ itself,
      # but a font is process-local state {Fonts} holds OUTSIDE the tree, so it has
      # to be handed back explicitly or lowering a `draw_text font: :whatever` fails
      # in a fresh process the way it never would in the process that built the ROM.
      # The built-in fonts need no entry here — re-requiring the library registers
      # those itself.
      def emit_class(program, class_name:, fast_cartridge:, fast_code:, fonts: {})
        body = source(program, level: 2)
        <<~RUBY
          # frozen_string_literal: true

          # The IR RubyGBA::IR::Backends::GBA would lower for this game — a snapshot, not
          # a live view: editing the game file does not change this file. Generated by
          # `ruby-gba build --format=ir`. Reconstructs the intermediate representation and
          # lowers it to machine code; nothing more — no ROM header, no checksum, no file
          # written. Run it directly to reproduce that codegen, e.g. to bisect a change to
          # the compiler.

          require "ruby_gba"
          #{font_registrations(fonts)}
          class #{class_name}
            def program
              #{body}
            end

            def lower
              RubyGBA::IR::Backends::GBA.new(fast_cartridge: #{fast_cartridge.inspect},
                                             fast_code: #{fast_code.inspect}).lower(program)
            end
          end

          #{class_name}.new.lower if $PROGRAM_NAME == __FILE__
        RUBY
      end

      # `RubyGBA::Fonts.register :name, RubyGBA::Font.new(...)` for each of +fonts+,
      # one call per line — empty when there are none, so a game with no custom
      # fonts (the common case) gets no extra lines at all.
      def font_registrations(fonts)
        fonts.map { |name, font| "RubyGBA::Fonts.register(#{name.inspect}, #{font_source(font)})\n" }.join
      end

      def font_source(font)
        args = font.to_definition.map { |key, value| "#{key}: #{value.inspect}" }
        "RubyGBA::Font.new(#{args.join(', ')})"
      end
    end
  end
end
