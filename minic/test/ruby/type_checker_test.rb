require './test_helper'
require 'minic/type_checker'

class TypeCheckerTest < Minitest::Test
  include Minic::Errors

  ### TYPES ###

  def test_type_goright
    types = [
      { id: "A", fields: [{ id: "a1", type: "int" }, { id: "a2", type: "bool" }] },
      { id: "B", fields: [] }
    ]
    prog = Minic::TypeChecker.new(input(types, [], []))

    refute_nil prog.struct_table["A"]
    assert_equal "struct", prog.struct_table["A"][:type]
    types[0][:fields].each do |f|
      assert_equal f[:type], prog.struct_table["A"][:fields][f[:id]]
    end

    refute_nil prog.struct_table["B"]
    assert_equal "struct", prog.struct_table["B"][:type]
    types[1][:fields].each do |f|
      assert_equal f[:type], prog.struct_table["B"][:fields][f[:id]]
    end
  end

  def test_type_allow_valid_fields
    type = { id: "A", fields: [{id: "a", type: nil}, {id: "b", "type": nil} ] }
    ["int", "bool", "A"].each do |field_type_1|
      type[:fields][0][:type] = field_type_1
      ["int", "bool", "A"].each do |field_type_2|
        type[:fields][1][:type] = field_type_2
        prog = Minic::TypeChecker.new(input([type], [], []))
        refute_nil prog.struct_table["A"]
        assert_equal field_type_1, prog.struct_table["A"][:fields]["a"]
        assert_equal field_type_2, prog.struct_table["A"][:fields]["b"]
      end
    end
  end

  def test_type_prevent_types_with_reserved_words
    type = { id: nil, fields: [] }
    ["int", "bool", "void", "null"].each do |id|
      type[:id] = id
      e = assert_raises TypeError do
        Minic::TypeChecker.new(input([type], [], []))
      end
      assert_match /cannot create struct/, e.message
    end
  end

  def test_type_allow_previous_struct_fields
    types = [
      { id: "A", fields: [] },
      { id: "B", fields: [{id: "a", type: "A"}] },
    ]
    prog = Minic::TypeChecker.new(input(types, [], []))

    refute_nil prog.struct_table["B"]
    assert_equal "struct", prog.struct_table["B"][:type]
    assert_equal "A", prog.struct_table["B"][:fields]["a"]
  end

  def test_type_prevent_future_struct_fields
    types = [
      { id: "A", fields: [{id: "a", type: "B"}] },
      { id: "B", fields: [] },
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input(types, [], []))
    end
    assert_match /is undefined/, e.message
  end

  def test_type_prevent_redefinitions
    types = [
      { id: "A", fields: [] },
      { id: "A", fields: [] },
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input(types, [], []))
    end
    assert_match /previous definition for/, e.message
  end

  def test_type_prevent_undefined_fields
    types = [
      { id: "A", fields: [{id: "a", type: "string"}] },
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input(types, [], []))
    end
    assert_match /is undefined/, e.message
  end

  def test_type_prevent_redefined_fields
    type = { id: "A", fields: [{id: "a", type: "bool"}, {id: "a", "type": "bool"} ] }
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([type], [], []))
    end
    assert_match /is already defined/, e.message
  end

  ### DECLARATIONS ###

  def test_declaration_goright
    decls = [
       {id: "a", type: "int"},
       {id: "b", type: "bool"}
    ]
    prog = Minic::TypeChecker.new(input([], decls, []))

    refute_nil prog.symbol_table["a"]
    assert_equal "int", prog.symbol_table["a"][:type]
    assert_equal "global", prog.symbol_table["a"][:scope]

    refute_nil prog.symbol_table["b"]
    assert_equal "bool", prog.symbol_table["b"][:type]
    assert_equal "global", prog.symbol_table["b"][:scope]
  end

  def test_declaration_allow_valid_types
    type = { id: "A", fields: [] }
    decl =  {id: "a", type: "A"}
    ["int", "bool", "A"].each do |decl_type|
      decl[:type] = decl_type
      prog = Minic::TypeChecker.new(input([type], [decl], []))
      refute_nil prog.symbol_table["a"]
      assert_equal decl_type, prog.symbol_table["a"][:type]
    end
  end

  def test_declaration_prevent_undefined_type
    decl = {id: "a", type: "A"}
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [decl], []))
    end
    assert_match /is undefined/, e.message
  end

  def test_declaration_prevent_redefinitions
    decls = [
      {id: "a", type: "int"},
      {id: "a", type: "int"},
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], decls, []))
    end
    assert_match /previous definition for/, e.message
  end

  ### FUNCTIONS ###

  def test_function_goright
    funcs = [ sample_function_1("f")]
    prog = Minic::TypeChecker.new(input([], [], funcs))

    refute_nil prog.symbol_table["f"]
    entry = prog.symbol_table["f"]
    assert_equal "function", entry[:type]
    assert_equal "global", entry[:scope]
    assert_equal "bool", entry[:return_type]

    assert_equal 1, entry[:params].count
    assert_equal ["a"], entry[:params].keys
    assert_equal "int", entry[:params]["a"]

    assert_equal 1, entry[:locals].count
    assert_equal ["b"], entry[:locals].keys
    assert_equal "int", entry[:locals]["b"]
  end

  def test_function_allow_structs
    types = [ { id: "A", fields: [] } ]
    funcs = [
      { id: "f", parameters: [ {id: "a", type: "A"} ], return_type: "A", declarations: [ { id: "b", type: "A" } ], body: [return_stmt("A")] }
    ]
    prog = Minic::TypeChecker.new(input(types, [], funcs))

    refute_nil prog.symbol_table["f"]
    entry = prog.symbol_table["f"]
    assert_equal "function", entry[:type]
    assert_equal "global", entry[:scope]
    assert_equal "A", entry[:return_type]

    assert_equal 1, entry[:params].count
    assert_equal ["a"], entry[:params].keys
    assert_equal "A", entry[:params]["a"]

    assert_equal 1, entry[:locals].count
    assert_equal ["b"], entry[:locals].keys
    assert_equal "A", entry[:locals]["b"]
  end


  def test_function_prevent_function_redefinitions
    f1 = { id: "f", parameters: [], return_type: "int", declarations: [], body: [return_stmt("int")] }
    f2 = { id: "f", parameters: [], return_type: "int", declarations: [], body: [return_stmt("int")] }
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], [f1, f2]))
    end
    assert_match /previous definition for/, e.message
  end

  def test_function_prevent_global_declaration_redefinition
    decl = { id: "f", type: "int" }
    func = { id: "f", parameters: [], return_type: "int", declarations: [], body: [return_stmt("int")] }
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [decl], [func]))
    end
    assert_match /previous definition for/, e.message
  end

  def test_function_prevent_wrong_return_type
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [], return_type: nil, declarations: [],
      body: [{stmt: "return", exp: { exp: nil, value: "1"}}]
    }
    ["int", "bool", "A"].each do |ret_type|
      func[:return_type] = ret_type
      ["num", "bool", "A", "null"].each do |exp_type|
        func[:body][0][:exp][:exp] = exp_type
        exp_type = "int" if exp_type == "num" # for easier checking
        if can_assign?(exp_type, ret_type)
          prog = Minic::TypeChecker.new(input([type], [], [func]))
          refute_nil prog.symbol_table["f"]
        else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input([type], [], [func]))
          end
          assert_match /invalid return type/, e.message
        end
      end
    end
  end

  def test_function_prevent_missing_returns
    types = [{ id: "A", fields: [] }]
    decls = [{ id: "g1", type: "int" }, { id: "g2", type: "A" }]
    func = { id: "f", parameters: [], return_type: "int", declarations: [], body: [] }
    not_ret_equiv_stmts = [
      { stmt: "block", list: [] },                                  # empty block
      { stmt: "assign", source: {exp: "num", value: "1"}, 
        target: {id: "g1"} },                                       # assignment
      { stmt: "delete", exp: {exp: "id", id: "g2"} },               # delete
      { stmt: "print", exp: {exp: "num", value: "2"}, endl: false },# print
      { stmt: "while", guard: {exp: "bool", value: "true"}, 
        body: {stmt: "block", list: []} },                          # while empty
      { stmt: "if", guard: { exp: "bool", value: "true"}, 
        then: { stmt: "block", list: [] } },                        # if-then empty
      { stmt: "if", guard: { exp: "bool", value: "true"}, 
        then: { stmt: "block", list: [] },         
        else: { stmt: "block", list: [] } },                        # if-then-else empty
      { stmt: "if", guard: { exp: "bool", value: "true"}, 
        then: { stmt: "block", list: [return_stmt("int")] },         
        else: { stmt: "block", list: [] } },                        # if-then, else empty
    ]

    ret_equiv_stmts = [
      { stmt: "return", exp: {exp: "num", value: "1"} },       # literally a return
      { stmt: "block", list: [return_stmt("int")] },           # block with a return
      { stmt: "while", guard: {exp: "bool", value: "true"}, 
        body: {stmt: "block", list: [return_stmt("int")]} },   # while with a return
      { stmt: "if", guard: { exp: "bool", value: "true"}, 
        then: { stmt: "block", list: [return_stmt("int")] } }, #if-then with a return
      { stmt: "if", guard: { exp: "bool", value: "true"}, 
        then: { stmt: "block", list: [return_stmt("int")] },         
        else: { stmt: "block", list: [return_stmt("int")] } }, # if-then-else with a return
    ]

    not_ret_equiv_stmts.each do |statement|
      func[:body] = [statement]
      e = assert_raises TypeError do
        Minic::TypeChecker.new(input(types, decls, [func]))
      end
      assert_match /control reaches end of non-void function/, e.message
    end

    ret_equiv_stmts.each do |statement|
      func[:body] = [statement]
      prog = Minic::TypeChecker.new(input(types, decls, [func]))
      refute_nil prog.symbol_table["f"]
    end
  end

  def test_function_without_main
    assert_raises CompileError do
      Minic::TypeChecker.new(input_without_main([], [], []))
    end

    func = { id: "main", parameters: [], return_type: "bool", declarations: [], body: [] }
    assert_raises TypeError do
      Minic::TypeChecker.new(input_without_main([], [], [func]))
    end

    func = { id: "main", parameters: [ {id: "a", type: "A"} ], return_type: "int", declarations: [], body: [] }
    assert_raises TypeError do
      Minic::TypeChecker.new(input_without_main([], [], [func]))
    end
  end

  ### STATEMENTS ###
  
  def test_statement_invalid
    func = { 
      id: "f", parameters: [ {id: "a", type: "int"} ], return_type: "int", declarations: [],
      body: [ { stmt: "z" }, return_stmt("int") ]
    }
    assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], [func]))
    end
  end
  
  def test_statement_assign
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [], return_type: "void", declarations: [{id: "a", type: nil}],
      body: [{stmt: "assign", source: {exp: nil, value: nil}, target: {id: "a"} }]
    }
    ["int", "bool", "A"].each do |left_type|
      func[:declarations][0][:type] = left_type
      ["num", "bool", "A", "null"].each do |right_type|
        func[:body][0][:source][:exp] = right_type
        right_type = "int" if right_type == "num" # for easier checking
        if can_assign?(right_type, left_type)
          prog = Minic::TypeChecker.new(input([type], [], [func]))
          refute_nil prog.symbol_table["f"]
        else
          assert_raises TypeError do
            Minic::TypeChecker.new(input([type], [], [func]))
          end
        end
      end
    end
  end


  def test_statement_assign_nested_target
    types = [ { id: "A", fields: [{ id: "i", type: "int"}] }, { id: "B", fields: [{ id: "a", type: "A" }] } ]
    func = {
      id: "f", parameters: [], return_type: "void", declarations: [{id: "b", type: "B"}],
      body: [{
        stmt: "assign", source: {exp: "num", value: "1"},
        target: {
            left: {
              left: { id: "b"},
              id: "a"
            },
            id: "i"
        }
      }]
    }
    prog = Minic::TypeChecker.new(input(types, [], [func]))
    refute_nil prog.symbol_table["f"]
  end

 
  def test_statement_if
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: "void", declarations: [],
      body: [{
        stmt: "if", 
        guard: { exp: nil, value: nil},  
        then: { stmt: "block", list: [] },
        else: { stmt: "block", list: [] }
      }]
    }

    ["int", "bool", "A"].each do |guard_type|
      func[:body][0][:guard][:exp] = guard_type
      if guard_type == "bool"
        prog = Minic::TypeChecker.new(input([type], [], [func]))
        refute_nil prog.symbol_table["f"]
      else
        e = assert_raises TypeError do
          Minic::TypeChecker.new(input([type], [], [func]))
        end
        assert_match /invalid guard of type/, e.message
      end
    end
  end

  def test_statement_if_without_else
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: "void", declarations: [],
      body: [{
        stmt: "if", 
        guard: { exp: "bool", value: "true"},  
        then: { stmt: "block", list: [] }
      }]
    }
    prog = Minic::TypeChecker.new(input([type], [], [func]))
    refute_nil prog.symbol_table["f"]
  end

  def test_statement_print
    type = { id: "A", fields: [] }
    func = {
      id: "f", parameters: [ ], return_type: "void", declarations: [],
      body: [{stmt: "print", exp: {exp: nil, value: nil}, endl: false }],
    }
    ["num", "bool", "A"].each do |t|
      func[:body][0][:exp][:exp] = t
      if t == "num"
        prog = Minic::TypeChecker.new(input([type], [], [func]))
        refute_nil prog.symbol_table["f"]
      else
        e = assert_raises TypeError do
          Minic::TypeChecker.new(input([type], [], [func]))
        end
        assert_match /cannot print type/, e.message
      end
    end
  end

  def test_statement_while
    type = { id: "A", fields: [] }
    func = {
      id: "f", parameters: [ ], return_type: "bool", declarations: [],
      body: [{
        stmt: "while", guard: {exp: nil, value: nil}, body: {stmt: "block", list: [return_stmt("bool")]}
      }]
    }
    ["num", "bool", "A"].each do |t|
      func[:body][0][:guard][:exp] = t
      if t == "bool"
        prog = Minic::TypeChecker.new(input([type], [], [func]))
        refute_nil prog.symbol_table["f"]
      else
        e = assert_raises TypeError do
          Minic::TypeChecker.new(input([type], [], [func]))
        end
        assert_match /invalid guard of type/, e.message
      end
    end
  end

  def test_statement_return
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: nil, declarations: [],
      body: [{stmt: "return", exp: {exp: nil, value: nil}}],
    }
    ["int", "bool", "A"].each do |f_ret_type|
      func[:return_type] = f_ret_type
      f_ret_type = "num" if f_ret_type == "int" # for easier checking
      ["num", "bool", "A"].each do |ret_type|
        func[:body][0][:exp][:exp] = ret_type
        if f_ret_type == ret_type
          prog = Minic::TypeChecker.new(input([type], [], [func]))
          refute_nil prog.symbol_table["f"]
        else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input([type], [], [func]))
          end
          assert_match /invalid return type/, e.message
        end
      end
    end

    func[:return_type] = "void"
    ["num", "bool", "A"].each do |ret_type|
      func[:body][0][:exp][:exp] = ret_type
      e = assert_raises TypeError do
        Minic::TypeChecker.new(input([type], [], [func]))
      end
      assert_match /invalid return type/, e.message
    end
  end

  def test_statement_delete
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: "void", declarations: [],
      body: [{stmt: "delete", exp: {exp: nil, value: nil}}],
    }
    ["num", "bool", "A"].each do |t|
      func[:body][0][:exp][:exp] = t
      if t == "A"
        prog = Minic::TypeChecker.new(input([type], [], [func]))
        refute_nil prog.symbol_table["f"]
      else
        e = assert_raises TypeError do
          Minic::TypeChecker.new(input([type], [], [func]))
        end
        assert_match /cannot delete type/, e.message
      end
    end
  end

  def test_statement_block
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: "int", declarations: [],
      body: [{
        stmt: "block", list: [
          {stmt: "print", exp: {exp: "int", value: nil}, endl: true },
          return_stmt("int")
        ]
      }]
    }
    prog = Minic::TypeChecker.new(input([type], [], [func]))
    refute_nil prog.symbol_table["f"]

    func[:body][0][:list][1][:exp][:exp] = "bool"
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([type], [], [func]))
    end
    assert_match /invalid return type/, e.message
  end

  def test_statement_invocation_goright
    funcs = [
    { 
      id: "f1", parameters: [{id: "a", type: "int"}], return_type: "int", declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}]
    },
    { 
      id: "f2", parameters: [], return_type: "int", declarations: [{id: "a", type: "int"}],
      body: [
        { stmt: "invocation", id: "f1", args: [{exp: "num", value: "2"}] },
        { stmt: "return", exp: {exp: "num", value: "1"} }]
    }
    ]
    prog = Minic::TypeChecker.new(input([], [], funcs))
    refute_nil prog.symbol_table["f1"]
    refute_nil prog.symbol_table["f2"]
  end

  def test_statement_invocation_wrong_argument_type
    funcs = [
    { 
      id: "f1", parameters: [{id: "a", type: "bool"}], return_type: "bool", declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}] 
    },
    { 
      id: "f2", parameters: [], return_type: "bool", declarations: [{id: "a", type: "int"}],
      body: [
        { stmt: "invocation", id: "f1", args: [{exp: "num", value: "1"}] },
        { stmt: "return", exp: {exp: "bool", value: "true"} }]
    }
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], funcs))
    end
    assert_match /wrong type for parameter/, e.message
  end

  def test_statement_invocation_arguments
    types = [{ id: "A", fields: [] }]
    funcs = [
    { 
      id: "f1", parameters: [{id: "a", type: nil}], return_type: nil, declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}] 
    },
    { 
      id: "f2", parameters: [], return_type: "int", declarations: [{id: "a", type: "int"}],
      body: [
        { stmt: "invocation", id: "f1", args: [{exp: nil, value: nil}] },
        { stmt: "return", exp: {exp: nil, value: nil} }]
    }
    ]
    ["int", "bool", "A"].each do |ret_type|
      funcs[0][:parameters][0][:type] = ret_type
      funcs[0][:return_type] = ret_type
      ["int", "bool", "A", "null"].each do |arg_type|
        funcs[1][:return_type] = ret_type
        funcs[1][:body][1][:exp][:exp] = ret_type
        funcs[1][:body][0][:args][0][:exp] = arg_type
        if can_assign?(arg_type, ret_type)
          prog = Minic::TypeChecker.new(input(types, [], funcs))
          refute_nil prog.symbol_table["f1"]
          refute_nil prog.symbol_table["f2"]
        else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input(types, [], funcs))
          end
          assert_match /wrong type for parameter/, e.message
        end
      end
    end
  end

  ### EXPRESSIONS ###
  
  def test_expression_dot
    type = { id: "A", fields: [{id: "a", type: "int"}] }
    func = { 
      id: "f", parameters: [ {id: "b", type: "A"} ], return_type: "int", declarations: [],
      body: [
        { stmt: "return", exp: { exp: "dot", left: {exp: "id", id: "b"}, id: "a" } },
      ]
    }
    prog = Minic::TypeChecker.new(input([type], [], [func]))
    refute_nil prog.symbol_table["f"]

    func[:parameters][0][:type] = "int"
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], [func]))
    end
    assert_match /is undefined/, e.message

    func[:parameters][0][:type] = "A"
    func[:body][0][:exp][:id] = "b"
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], [func]))
    end
    assert_match /is undefined/, e.message
  end

  def test_expression_binary_invalid_op
    func = { 
      id: "f", parameters: [ ], return_type: "bool", declarations: [],
      body: [{stmt: "return", exp: {exp: "binary", operator: "x", lft: {exp: nil, value: nil}, rht: {exp: nil, value: nil}}}]
    }
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], [func]))
    end
    assert_match /is not a valid binary operator/, e.message
  end

  def test_expression_binary_boolean_ops
    type = { id: "A", fields: [] }
    func = { 
      id: "f", parameters: [ ], return_type: "bool", declarations: [],
      body: [{stmt: "return", exp: {exp: "binary", operator: nil, lft: {exp: nil, value: nil}, rht: {exp: nil, value: nil}}}]
    }
    ["&&", "||"].each do |op|
      ["num", "bool", "A"].each do |left|
        ["num", "bool", "A"].each do |right|
          func[:body][0][:exp][:operator] = op
          func[:body][0][:exp][:lft][:exp] = left
          func[:body][0][:exp][:rht][:exp] = right
          if left == right and left == "bool"
            prog = Minic::TypeChecker.new(input([type], [], [func]))
            refute_nil prog.symbol_table["f"]
          else
            e = assert_raises TypeError do
              Minic::TypeChecker.new(input([type], [], [func]))
            end
            assert_match /cannot accept operands of type/, e.message
          end
        end
      end
    end
  end

  def test_expression_binary_eq_ops
    type = { id: "A", fields: [] }
    func = { id: "f", parameters: [ ], return_type: "bool", declarations: [],
             body: [{stmt: "return", exp: {exp: "binary", operator: nil, lft: {exp: nil, value: "1"}, rht: {exp: nil, value: "1"}}} ],
    }
    ["==", "!="].each do |op|
      ["num", "bool", "A"].each do |left|
        ["num", "bool", "A", "null"].each do |right|
          func[:body][0][:exp][:operator] = op
          func[:body][0][:exp][:lft][:exp] = left
          func[:body][0][:exp][:rht][:exp] = right
          if can_compare_eq?(left, right)
            prog = Minic::TypeChecker.new(input([type], [], [func]))
            refute_nil prog.symbol_table["f"]
          else
            e = assert_raises TypeError do
              Minic::TypeChecker.new(input([type], [], [func]))
            end
            assert_match /cannot be compared to/, e.message
          end
        end
      end
    end
  end

  def test_expression_binary_rel_ops
    type = { id: "A", fields: [] }
    func = { id: "f", parameters: [ ], return_type: "bool", declarations: [],
      body: [{stmt: "return", exp: {exp: "binary", operator: nil, lft: {exp: nil, value: "1"}, rht: {exp: nil, value: "1"}}} ],
    }
    ["<", ">", "<=", ">="].each do |op|
      ["num", "bool", "A"].each do |left|
        ["num", "bool", "A"].each do |right|
          func[:body][0][:exp][:operator] = op
          func[:body][0][:exp][:lft][:exp] = left
          func[:body][0][:exp][:rht][:exp] = right
          if left == right and right == "num"
            prog = Minic::TypeChecker.new(input([type], [], [func]))
            refute_nil prog.symbol_table["f"]
          else
            e = assert_raises TypeError do
              Minic::TypeChecker.new(input([type], [], [func]))
            end
            assert_match /cannot accept operands of type/, e.message
          end
        end
      end
    end
  end

  def test_expression_binary_arith_ops
    type = { id: "A", fields: [] }
    func = { id: "f", parameters: [ ], return_type: "int", declarations: [],
      body: [{stmt: "return", exp: {exp: "binary", operator: nil, lft: {exp: nil, value: nil}, rht: {exp: nil, value: nil}}} ],
    }
    ["+", "-", "*", "/"].each do |op|
      ["num", "bool", "A"].each do |left|
        ["num", "bool", "A"].each do |right|
          func[:body][0][:exp][:operator] = op
          func[:body][0][:exp][:lft][:exp] = left
          func[:body][0][:exp][:rht][:exp] = right
          if left == right and left == "num"
            prog = Minic::TypeChecker.new(input([type], [], [func]))
            refute_nil prog.symbol_table["f"]
          else
            e = assert_raises TypeError do
              Minic::TypeChecker.new(input([type], [], [func]))
            end
            assert_match /cannot accept operands of type/, e.message
          end
        end
      end
    end
  end

  def test_expression_unary_ops
    type = { id: "A", fields: [] }
    func = { id: "f", parameters: [ ], return_type: nil, declarations: [],
      body: [{stmt: "return", exp: {exp: "unary", operator: nil, operand: {exp: nil, value: nil}}}],
    }
    ["!", "-"].each do |op|
      func[:return_type] = op == "!" ? "bool" : "int"
      ["num", "bool", "A"].each do |operand|
        func[:body][0][:exp][:operator] = op
        func[:body][0][:exp][:operand][:exp] = operand
        if (op == "!" && operand == "bool") or (op == "-" && operand == "num")
            prog = Minic::TypeChecker.new(input([type], [], [func]))
            refute_nil prog.symbol_table["f"]
        else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input([type], [], [func]))
          end
          assert_match /cannot accept operand of type/, e.message
        end
      end
    end
  end

  def test_expression_new
    type = { id: "A", fields: [] }
    func = {
      id: "f", parameters: [], return_type: nil, declarations: [],
      body: [{ stmt: "return", exp: { exp: "new", id: nil }}]
    }
    ["int", "bool", "A"].each do |new_type|
      func[:return_type] = new_type
      func[:body][0][:exp][:id] = new_type
      if new_type == "A"
        prog = Minic::TypeChecker.new(input([type], [], [func]))
        refute_nil prog.symbol_table["f"]
      else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input([type], [], [func]))
          end
          if new_type == "int" or new_type == "bool"
            assert_match /cannot allocate type/, e.message
          else
            assert_match /is undefined/, e.message
          end
      end
    end
  end

  def test_expression_invocation_goright
    funcs = [
    { id: "f1", parameters: [{id: "a", type: "int"}], return_type: "int", declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}] },
    { id: "f2", parameters: [], return_type: "int", declarations: [{id: "a", type: "int"}],
      body: [{ stmt: "return", exp: { exp: "invocation", id: "f1", args: [{exp: "num", value: "2"}] }}],
    }
    ]
    prog = Minic::TypeChecker.new(input([], [], funcs))
    refute_nil prog.symbol_table["f1"]
    refute_nil prog.symbol_table["f2"]
  end

  def test_expression_invocation_wrong_argument_type
    funcs = [
    { id: "f1", parameters: [{id: "a", type: "bool"}], return_type: "bool", declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}] },
    { id: "f2", parameters: [], return_type: "bool", declarations: [{id: "a", type: "int"}],
      body: [{ stmt: "return", exp: { exp: "invocation", id: "f1", args: [{exp: "num", value: "1"}] }}],
    }
    ]
    e = assert_raises TypeError do
      Minic::TypeChecker.new(input([], [], funcs))
    end
    assert_match /wrong type for parameter/, e.message
  end


  def test_expression_invocation_arguments
    types = [{ id: "A", fields: [] }]
    funcs = [
    { id: "f1", parameters: [{id: "a", type: nil}], return_type: nil, declarations: [],
      body: [{ stmt: "return", exp: { exp: "id", id: "a" }}] },
    { id: "f2", parameters: [], return_type: "void", declarations: [],
      body: [{ stmt: "return", exp: { exp: "invocation", id: "f1", args: [{exp: nil, value: nil}] }}],
    }
    ]
    ["int", "bool", "A"].each do |ret_type|
      funcs[0][:parameters][0][:type] = ret_type
      funcs[0][:return_type] = ret_type
      ["int", "bool", "A", "null"].each do |arg_type|
        funcs[1][:return_type] = ret_type
        funcs[1][:body][0][:exp][:args][0][:exp] = arg_type
        if can_assign?(arg_type, ret_type)
          prog = Minic::TypeChecker.new(input(types, [], funcs))
          refute_nil prog.symbol_table["f1"]
          refute_nil prog.symbol_table["f2"]
        else
          e = assert_raises TypeError do
            Minic::TypeChecker.new(input(types, [], funcs))
          end
          assert_match /wrong type for parameter/, e.message
        end
      end
    end
  end

  ### MISC ###
  
  def test_allow_infinite_recursion
    func = {
      id: "f", parameters: [], return_type: "int", declarations: [],
      body: [
        { stmt: "return", exp: { exp: "invocation", id: "f", args: [] } },
      ]
    }
    prog = Minic::TypeChecker.new(input([], [], [func]))
    refute_nil prog.symbol_table["f"]
  end

  def test_file_1_mini
    filename = "../../files/1.mini.json"
    Minic::TypeChecker.generate_from_json_file(filename)
  end

  def test_file_2_mini
    filename = "../../files/2.mini.json"
    e = assert_raises TypeError do
      Minic::TypeChecker.generate_from_json_file(filename)
    end
    assert_match /invalid return type/, e.message
  end

  def test_file_2_fixed_mini
    filename = "../../files/2_fixed.mini.json"
    Minic::TypeChecker.generate_from_json_file(filename)
  end

  def test_file_ret_mini
    filename = "../../files/ret.mini.json"
    e = assert_raises CompileError do
      Minic::TypeChecker.generate_from_json_file(filename)
    end
    assert_match /no valid main function found/, e.message
  end

  def test_file_ret_fixed_mini
    filename = "../../files/ret_fixed.mini.json"
    Minic::TypeChecker.generate_from_json_file(filename)
  end

  ### HELPERS ###

  def input(types=[], decls=[], funcs=[])
    main = { 
      id: "main", parameters: [], return_type: "int", declarations: [], 
      body: [{stmt: "return", exp: {exp: "num", value: "0"}}] }
    {
      types:        types,
      declarations: decls,
      functions:    (funcs + [main])
    }
  end

  def input_without_main(types=[], decls=[], funcs=[])
    {
      types:        types,
      declarations: decls,
      functions:    funcs
    }
  end

  def sample_function_1(id)
    # fun f(int a) bool {
    #   int b;
    #   b = 3;
    #   if (a < b) {
    #     return true;
    #   } else {
    #     return false;
    #   }
    # }
    {
      id: id,
      parameters: [ {id: "a", type: "int"} ],
      return_type: "bool",
      declarations: [ { id: "b", type: "int" } ], 
      body: [
        {
          stmt: "assign",
          source: { exp: "num", value: "2" },
          target: { id: "b" },
        },
        {
          stmt: "if",
          guard: {
            exp: "binary",
            operator: "<",
            lft: { exp: "id", id: "a" },
            rht: { exp: "id", id: "b" },
          },
          then: {
            stmt: "block",
            list: [{
              stmt: "return",
              exp: { 
                exp: "bool",
                value: "true"
              }
            }]
          },
          else: {
            stmt: "block",
            list: [{
              stmt: "return",
              exp: { 
                exp: "bool",
                value: "true"
              }
            }]
          }
        }
      ]
    }
  end

  def sample_function_missing_return(id)
    # fun f(int a, int b) bool {
    #   if (a < b) {
    #     return true;
    #   } else { }
    # }
    {
      id: id,
      parameters: [ {id: "a", type: "int"}, {id: "b", type: "int"} ],
      return_type: "bool",
      declarations: [],
      body: [
        stmt: "if",
        guard: {
          exp: "binary",
          operator: "<",
          lft: { exp: "id", id: "a" },
          rht: { exp: "id", id: "b" },
        },
        then: {
          stmt: "block",
          list: [{
            stmt: "return",
            exp: { 
              exp: "bool",
              value: "true"
            }
          }]
        }
      ]
    }
  end

  def sample_function_lt2
    { 
      id: "lt2", parameters: [ {id: "a", type: "int"} ], return_type: "int", declarations: [],
      body: [
        {
          stmt: "if",
          guard: {
            exp: "binary",
            operator: "<",
            lft: { exp: "id", id: "a" },
            rht: { exp: "num", id: "2" },
          },
          then: {
            stmt: "block",
            list: [{
              stmt: "return",
              exp: { 
                exp: "num",
                value: "1"
              }
            }]
          },
          else: {
            stmt: "block",
            list: [{
              stmt: "return",
              exp: { 
                exp: "num",
                value: "0"
              }
            }]
          }
        }
      ]
    }
  end

  def can_assign?(source, target)
    source == target or (source == "null" and !["int", "bool", "null"].include?(target))
  end

  def can_compare_eq?(left, right)
    left == right && left != "bool" or
    (!["int", "num", "bool"].include?(left) && right == "null") or
    (!["int", "num", "bool"].include?(right) && left == "null")
  end

 def return_stmt(type)
    {stmt: "return", exp: {exp: type, value: nil}}
  end
end
