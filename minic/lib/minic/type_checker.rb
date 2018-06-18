require 'json'
require 'pry'
require 'minic/errors'

def warning(msg, line)
  puts "Compile Warning (line #{line or '?'}): #{msg}"
end

class Minic::TypeChecker
  include Minic::Errors

  attr_reader :ast, :struct_table, :global_table, :function_table

  class << self
    def generate_from_json_file(filename)
      File.open(filename, 'r') do |file|
        self.new(JSON.parse(file.read, symbolize_names: true))
      end
    end
  end

  def initialize(ast)
    @ast = ast
    @struct_table = {}
    @global_table = {}
    @function_table = {}
    (ast[:types] and ast[:types].is_a? Array) or raise ASTError.new("ast is missing :types", ast)
    (ast[:declarations] and ast[:declarations].is_a? Array) or raise ASTError.new("ast is missing :declarations", ast)
    (ast[:functions] and ast[:functions].is_a? Array) or raise ASTError.new("ast is missing :functions", ast)

    check_types(ast[:types])
    check_decls(ast[:declarations])
    check_funcs(ast[:functions])
  end

  def symbol_table
    @global_table.merge(@function_table)
  end

  def to_h
    {
      ast: @ast,
      struct_table: @struct_table,
      global_table: @global_table,
      function_table: @function_table
    }
  end

  def to_json
    JSON.dump(to_h)
  end

  private

  def check_types(types)
    types.each do |type|
      id = type[:id] or raise ASTError.new("type is missing :id", type)
      # Don't allow redefinition of types
      unless @struct_table[id].nil?
        raise TypeError.new("previous definition for '#{id}'", type[:line])
      end
      if ["int", "bool", "void", "null"].include? id
        raise TypeError.new("cannot create struct '#{id}' (reserved)", type[:line])
      end
      @struct_table[id] = { type: "struct", fields: {} }
      (type[:fields] or []).each do |field|
        # Don't allow multiple fields with same id
        if @struct_table[id][:fields].keys.include? field[:id]
          raise TypeError.new("field '#{field[:type]}' is already defined in '#{id}'", field[:line])
        end
        # Don't allow undefined types
        unless valid_type?(field[:type])
          raise TypeError.new("type '#{field[:type]}' is undefined", field[:line])
        end
        @struct_table[id][:fields][field[:id]] = field[:type]
      end
    end
  end

  def check_decls(declarations)
    declarations.each do |decl|
      id = decl[:id] or raise ASTError.new("declaration is missing :id", decl)
      if symbol_defined?(id)
        # Don't allow redefinition of functions/vars
        raise TypeError.new("previous definition for '#{id}'", decl[:line])
      end
      @global_table[id] = {}
      decl[:type] or raise ASTError.new("declaration is missing :type", decl)
      # Don't allow undefined types
      unless valid_type?(decl[:type])
        raise TypeError.new("type #{decl[:type]}' is undefined", decl[:line])
      end
      @global_table[id] = { type: decl[:type], scope: "global" }
    end
  end

  def check_funcs(functions)
    functions.each do |func|
      id = func[:id] or raise ASTError.new("function is missing :id", func)
      if symbol_defined?(id)
        # Don't allow redefinition of functions/vars
        raise TypeError.new("previous definition for '#{id}'", func[:line])
      end
      @function_table[id] = { type: "function", scope: "global" }
      params = {}
      (func[:parameters] or []).each do |param|
        param[:id] or raise ASTError.new("param is missing :id", param)
        if params.keys.include? param[:id]
          # Don't allow redefinitions of parameters
          raise TypeError.new("previous definition for param '#{param[:id]}'", param[:line])
        end
        params[param[:id]] = param[:type] or raise ASTError.new("param is missing :type", param)
        unless valid_type?(param[:type])
          # Don't allow param of undefined type
          raise TypeError.new("param '#{param[:id]}' has type '#{param[:type]}' which is undefined", param[:line])
        end
      end
      @function_table[id][:params] = params
      func[:return_type] or raise ASTError.new("function is missing :return_type", func)
      unless valid_type?(func[:return_type], ["void"])
        # Don't allow return type of undefined type
        raise TypeError.new("return type for '#{id}' is '#{func[:return_type]}' which is undefined", func[:line])
      end
      @function_table[id][:return_type] = func[:return_type]
      decls = {}
      (func[:declarations] or []).each do |decl|
        decl[:id] or raise ASTError.new("declaration is missing :id", decl)
        # Don't allow locals to hide params
        if params.keys.include? decl[:id]
          raise TypeError.new("previous defintion for param '#{decl[:id]}'", decl[:line])
        end
        decls[decl[:id]] = decl[:type] or raise ASTError.new("declaration is missing :type", decl)
        # Don't allow locals of undefined type
        unless valid_type?(decl[:type])
          raise TypeError.new("local declaration '#{decl[:id]}' has type '#{decl[:type]}' which is undefined", decl[:line])
        end
      end
      @function_table[id][:locals] = decls
      func[:body] or raise ASTError.new("function is missing :body", func)
      check_func_body(id, func[:body], func[:line])
    end
    check_main
  end

  def symbol_defined?(id)
    !!(@global_table[id] or @function_table[id])
  end

  def check_main
    main = @function_table["main"]
    if !main || !main[:params].empty? || main[:return_type] != "int"
      raise CompileError.new("no valid main function found")
    end
  end

  def check_func_body(func_id, body, line)
    body.each_with_index do |statement, index|
      result = check_stmt(func_id, statement)
      if result[:return_equivalent]
        return
      end
    end
    unless @function_table[func_id][:return_type] == "void"
      raise TypeError.new("control reaches end of non-void function '#{func_id}'", line)
    end
  end

  def check_stmt(func_id, stmt)
    case (stmt[:stmt] or raise ASTError.new("statement is missing :stmt", stmt))
    when "invocation"
      check_invocation_statement(func_id, stmt)
    when "print"
      check_print(func_id, stmt)
    when "if"
      check_if(func_id, stmt)
    when"while"
      check_while(func_id, stmt)
    when "assign"
      check_assign(func_id, stmt)
    when "return"
      check_return(func_id, stmt)
    when "block"
      check_block(func_id, stmt)
    when"delete"
      check_delete(func_id, stmt)
    else
      raise TypeError.new("invalid statement type '#{stmt[:stmt]}'", stmt[:line])
    end
  end

  def check_invocation_statement(func_id, stmt)
    check_invocation(func_id, stmt)
    { return_equivalent: false }
  end

  def check_if(func_id, stmt)
    check_guard(func_id, stmt)
    then_br = stmt[:then] or raise ASTError.new("if statement is missing :then", stmt)
    then_br[:stmt] == "block" or raise ASTError.new("if statement then is not of type block", then_br)
    then_br = check_block(func_id, then_br)

    if stmt[:else]
      else_br = stmt[:else]
      else_br[:stmt] == "block" or raise ASTError.new("if statement else is not of type block", else_br)
      else_br = check_block(func_id, else_br)
      { return_equivalent: then_br[:return_equivalent] && else_br[:return_equivalent] }
    else
      { return_equivalent: then_br[:return_equivalent] }
    end
  end

  def check_while(func_id, stmt)
    check_guard(func_id, stmt)
    body = stmt[:body] or raise ASTError.new("while statement is missing :body", stmt) 
    body[:stmt] == "block" or raise ASTError.new("while statement body is not of type block", body) 
    check_block(func_id, body)
  end

  def check_block(func_id, stmt)
    list = stmt[:list] or raise ASTError.new("block statement is missing :list", stmt)
    list.each_with_index do |statement, index|
      result = check_stmt(func_id, statement)
      if result[:return_equivalent]
        return { return_equivalent: true }
      end
    end
    { return_equivalent: false }
  end

  def check_delete(func_id, stmt)
    exp = stmt[:exp] or raise ASTError.new("delete statement is missing :exp", stmt)
    exp_type = check_exp(func_id, exp)
    if exp_type == "int" or exp_type == "bool"
      raise TypeError.new("cannot delete type '#{exp_type}'", exp[:line])
    end
    { return_equivalent: false }
  end

  def check_print(func_id, stmt)
    exp = stmt[:exp] or raise ASTError.new("print statement is missing :exp", stmt)
    print_type = check_exp(func_id, exp)
    if print_type != "int"
      raise TypeError.new("cannot print type '#{print_type}'", exp[:line])
    end
    { return_equivalent: false }
  end

  def check_guard(func_id, stmt)
    guard = stmt[:guard] or raise ASTError.new("if/while is missing :guard", stmt)
    guard_type = check_exp(func_id, guard)
    if guard_type != "bool"
      raise TypeError.new("invalid guard of type '#{guard_type}'" , guard[:line])
    end
  end

  def check_assign(func_id, stmt)
    source = stmt[:source] or raise ASTError.new("assign is missing :source", stmt)
    target = stmt[:target] or raise ASTError.new("assign is missing :target", stmt)
    source_type = check_exp(func_id, source)
    if target[:exp]
      target_type = check_exp(func_id, target)
    elsif target[:left]
      target_type = lookup_in_struct(func_id, target[:left], target[:id], target[:line])
    else
      id = target[:id] or raise ASTError.new("assign is missing :target:id", type)
      target_type = lookup_id(func_id, id, stmt[:line])
    end
    unless can_assign?(source_type, target_type)
      raise TypeError.new("cannot assign '#{source_type}' into '#{target_type}'" , source[:line])
    end
    { return_equivalent: false }
  end

  def check_return(func_id, stmt)
    exp = stmt[:exp]
    expected = @function_table[func_id][:return_type]
    if exp
      actual = check_exp(func_id, exp)
      unless can_assign?(actual, expected)
        raise TypeError.new("invalid return type '#{actual}' for '#{expected}'" , exp[:line])
      end
    else
      if expected != "void"
        raise TypeError.new("void function '#{func_id}' should not return a value" , stmt[:line])
      end
    end
    { return_equivalent: true }
  end

  def check_exp(func_id, exp)
    case (exp[:exp] or raise ASTError.new("expression is missing :exp", exp))
    when "invocation"
      check_invocation(func_id, exp)
    when "binary"
      check_binary(func_id, exp)
    when "unary"
      check_unary(func_id, exp)
    when "dot"
      check_dot(func_id, exp)
    when "new"
      check_new(func_id, exp)
    when "read"
      "int"
    when "true", "false"
      "bool"
    when "null"
      "null"
    when "num", "int"
      "int"
    when "bool"
      "bool"
    when "id"
      lookup_id(func_id, exp[:id], exp[:line])
    else
      if exp[:id]
        lookup_id(func_id, exp[:id], exp[:line])
      elsif @struct_table[exp[:exp]]
        exp[:exp]
      else
        raise TypeError.new("invalid expression type '#{exp[:exp]}'", exp[:line])
      end
    end
  end

  def check_new(func_id, exp)
    id = exp[:id] or raise ASTError.new("new expression is missing :id", exp)
    if ["int", "bool", "void", "null"].include? exp[:id]
      raise TypeError.new("cannot allocate type '#{exp[:id]}'", exp[:line])
    end
    unless @struct_table[exp[:id]]
      raise TypeError.new("type '#{exp[:id]}' is undefined", exp[:line])
    end
    exp[:id]
  end

  def check_invocation(func_id, exp)
    id = exp[:id] or raise ASTError.new("invocation expression is missing :id", exp)
    func = @function_table[id]
    if func.nil?
      raise TypeError.new("function '#{id}' is undefined", exp[:line])
    end
    args = exp[:args] or []
    if args.count != func[:params].count
      raise TypeError.new("wrong number of arguments for function '#{id}',"\
                             "expected #{func[:params].count} got #{args.count}", exp[:line])
    end
    func_params = func[:params].map {|_,v| v}
    (args or []).each_with_index do |arg, i|
      target = func_params[i]
      source = check_exp(func_id, arg)
      unless can_assign?(source, target)
        raise TypeError.new("wrong type for parameter #{i} of function '#{id}',"\
                               "expected '#{target}' got '#{source}'", exp[:line])
      end
    end
    @function_table[id][:return_type]
  end

  def check_dot(func_id, exp)
    left = exp[:left] or raise ASTError.new("dot expression is missing :left", exp)
    id = exp[:id] or raise ASTError.new("dot expression is missing :id", exp)
    lookup_in_struct(func_id, check_exp(func_id, left), id, exp[:line])
  end

  def check_unary(func_id, exp)
    operator = exp[:operator] or raise ASTError.new("unary expression is missing :operator", exp)
    operand = exp[:operand] or raise ASTError.new("unary expression is missing :operand", exp)
    unless ["!", "-"].include? operator
      raise TypeError.new("'#{operator}' is not a valid unary operator", exp[:line])
    end
    operand_type = check_exp(func_id, operand)
    case operator
    when "!"
      if operand_type != "bool"
        raise TypeError.new("unary operator '!' cannot accept operand of type '#{operand_type}'"\
                               ", requires operand of type 'bool'", exp[:line])
      end
      "bool"
    when "-"
      if operand_type != "int"
        raise TypeError.new("unary operator '-' cannot accept operand of type '#{operand_type}'"\
                               ", requires operand of type 'int'", exp[:line])
      end
      "int"
    end
  end

  def check_binary(func_id, exp)
    operator = exp[:operator] or raise ASTError.new("binary expression is missing :operator", exp)
    left = exp[:lft] or raise ASTError.new("binary expression is missing :lft", exp)
    right = exp[:rht] or raise ASTError.new("binary expression is missing :rht", exp)
    unless ["<", ">", "<=", ">=", "+", "-", "*", "/", "&&", "||", "==", "!="].include? operator
      raise TypeError.new("'#{operator}' is not a valid binary operator", exp[:line])
    end
    lft_type = check_exp(func_id, left)
    rht_type = check_exp(func_id, right)
    case operator
    when "<", ">", "<=", ">="
      if lft_type != rht_type or lft_type != "int"
        raise TypeError.new("binary operator '#{operator}' cannot accept operands of type '#{lft_type}' '#{rht_type}'"\
                               ", requires operands of type 'int', 'int'", exp[:line])
      end
      "bool"
    when  "+", "-", "*", "/"
      if lft_type != rht_type or lft_type != "int"
        raise TypeError.new("binary operator '#{operator}' cannot accept operands of type '#{lft_type}' '#{rht_type}'"\
                               ", requires operands of type 'int', 'int'", exp[:line])
      end
      "int"
    when "&&", "||"
      if lft_type != rht_type or lft_type != "bool"
        raise TypeError.new("binary operator '#{operator}' cannot accept operands of type '#{lft_type}' '#{rht_type}',"\
                               "requires operands of type 'bool', 'bool'", exp[:line])
      end
      "bool"
    when "==", "!="
      unless can_compare_eq?(lft_type, rht_type)
        raise TypeError.new("'#{lft_type}' cannot be compared to '#{rht_type}'", exp[:line])
      end
      "bool"
    end
  end

  def lookup_in_struct(func_id, struct_name, id, line)
    if struct_name.is_a? String
      if @struct_table[struct_name].nil?
        raise TypeError.new("structure type '#{struct_name}' is undefined", line)
      end
      if @struct_table[struct_name][:fields][id].nil?
        raise TypeError.new("field '#{id}' in struct '#{struct_name}' is undefined", line)
      end
      @struct_table[struct_name][:fields][id]
    elsif struct_name[:left]
      struct_name[:id] or raise ASTError("struct reference has :left but no :id", struct_name)
      left = lookup_in_struct(func_id, struct_name[:left], struct_name[:id], struct_name[:line])
      #left_type = lookup_id(func_id, left_id, struct_name[:line])
      lookup_in_struct(func_id, left, id, line)
    elsif struct_name[:id]
      type = lookup_id(func_id, struct_name[:id], struct_name[:line])
      lookup_in_struct(func_id, type, id, line)
    else
      raise ASTError.new("invalid struct reference", struct_name)
    end
  end

  def lookup_id(func_id, id, line)
    @function_table[func_id] or raise TypeError.new("'#{id}' is not defined", line)
    local = (@function_table[func_id][:locals][id] or @function_table[func_id][:params][id])
    if local
      local
    else
      global = @global_table[id] or raise TypeError.new("'#{id}' is not defined", line)
      global[:type]
    end
  end

  def can_assign?(source, target)
    source == target or (source == "null" and !["int", "bool", "null"].include?(target))
  end

  def can_compare_eq?(left, right)
    left == right && left != "bool" or
      (!["int", "num", "bool"].include?(left) && right == "null") or
      (!["int", "num", "bool"].include?(right) && left == "null")
  end

  def valid_type?(type, addl=[])
    (@struct_table.keys + addl + ["int", "bool"]).include? type
  end

end


