require './test_helper'
require 'minic/cfg'
require 'minic/type_checker'

class TypeCheckerTest < Minitest::Test
  include Minic::Errors

  def test_input_validation
    input = {
      ast: {},
      struct_table: {},
      global_table: {},
      function_table: {}
    }
    [:ast, :struct_table, :global_table, :function_table].each do |missing|
      e = assert_raises CFGError do
        Minic::CFG.generate(input.select {|i| i != missing})
      end
      assert_match /missing :#{missing.to_s}/, e.message
    end
  end

  def test_baseline
    input = typecheck("./files/baseline.json")
    cfg = Minic::CFG.new(input)

    refute_nil cfg.struct_table["foo"] 
    refute_nil cfg.struct_table["simple"] 
    refute_nil cfg.function_table["test"]
    refute_nil cfg.function_table["main"]

    graphs = cfg.graphs

    refute_nil graphs["test"]
    refute_nil graphs["main"]

    # @ TODO I really don't want to write unit tests for this, consider just checking generated graphs
  end

  def typecheck(filename)
    Minic::TypeChecker.new(JSON.parse(File.read(filename), symbolize_names: true)[:ast]).to_h
  end
end
