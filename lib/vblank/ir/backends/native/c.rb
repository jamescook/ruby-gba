# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # THE C THE BACKEND WRITES, as data rather than text.
        #
        # The lowering builds these and the Printer alone turns them into text, so the things
        # that are easy to get wrong by hand — how a number is spelt, which names are legal,
        # indentation, what a comment may contain — are settled in one place, and no lowering
        # method ever glues C together out of strings.
        #
        # It is small on purpose. The game's numbers only ever go through rg_int32.h (see the
        # comment atop Native), so an expression here is a number, a name, the address of a
        # name, a piece of text, or a call — there are no operators, and so no precedence to
        # get wrong.
        module C
          # --- expressions ---

          # A whole number, written so C reads it as the int32_t it is.
          Int = Data.define(:value)

          # An identifier. Only Names hands these out, so every one is legal and none collide.
          Name = Data.define(:text)

          # &name: where a global lives, for a runtime function that fills it in.
          AddressOf = Data.define(:name)

          # A piece of text, as a C string. The printer escapes it.
          Text = Data.define(:value)

          Call = Data.define(:function, :args) do
            def initialize(function:, args: [])
              super
            end
          end

          # name[index], for reading a table or a list.
          Index = Data.define(:array, :index)

          # --- statements ---

          # A call whose answer nobody keeps.
          Eval = Data.define(:call)

          # target = value; the target is a Name or an Index.
          Assign = Data.define(:target, :value)

          # A local variable of the routine, int32_t unless said.
          Local = Data.define(:name, :value, :type) do
            def initialize(name:, value:, type: "int32_t")
              super
            end
          end

          # Taken when +condition+ is not nought, the way the game's conditions are numbers.
          If = Data.define(:condition, :body, :otherwise) do
            def initialize(condition:, body:, otherwise: [])
              super
            end
          end

          While = Data.define(:condition, :body)
          Break = Data.define
          Return = Data.define

          # { ... }, so a loop's own locals stay its own.
          Block = Data.define(:body)

          # A comment on a line of its own: where in the game a piece of C came from.
          Comment = Data.define(:text)

          # --- the top level ---

          Include = Data.define(:header)

          # A global the game keeps, starting at +value+.
          Global = Data.define(:name, :value, :type) do
            def initialize(name:, value: 0, type: "int32_t")
              super
            end
          end

          # Numbers fixed when the program is built: a table, a picture. +exported+ is for the
          # art the runtime reads by name (see runtime/rg_screen.h).
          ConstArray = Data.define(:name, :type, :values, :exported) do
            def initialize(name:, type:, values:, exported: false)
              super
            end
          end

          # A routine taking nothing and giving nothing back. +exported+ is for the few the
          # runtime calls by name; the rest are private to the generated file.
          Function = Data.define(:name, :body, :exported) do
            def initialize(name:, body:, exported: false)
              super
            end
          end

          # Declares a routine before its body, so routines can call each other in any order.
          Prototype = Data.define(:name, :exported) do
            def initialize(name:, exported: false)
              super
            end
          end

          # An array of routines, for calling one by its number.
          FunctionTable = Data.define(:name, :functions)

          # A game's list (see runtime/rg_list.h): +items+ is the array behind it, +capacity+
          # long, each slot +width+ bytes; +label+ is the game's name for it, for messages.
          ListStorage = Data.define(:name, :items, :capacity, :width, :label)
        end
      end
    end
  end
end
