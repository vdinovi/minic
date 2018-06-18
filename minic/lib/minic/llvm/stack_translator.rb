module Minic::LLVM
  class StackTranslator
    include Minic::Errors

    def initialize(struct_table, global_table, function_table)
      @struct_table = struct_table
      @global_table = global_table
      @function_table = function_table
    end

    def typeof(orig)
      if ["int", "num", "bool"].include? orig
        "i32"
      elsif orig == "void"
        "void"
      else
        "%struct.#{orig}*"
      end
    end

    def struct_declaration(name, type)
      fields = type[:fields].collect {|_, f| typeof(f)}
      [Instruction.struct_decl(name: name, fields: fields)]
    end

    def global_declaration(name, type)
      value = ["int", "bool"].include?(type[:type]) ? "1" : "null"
      target_reg = Register.name(name, typeof(type[:type]))
      target_reg.immediate = value
      target_reg.global = true
      [Instruction.global_decl(target: target_reg)]
    end

    def func_declaration(func_id, func)
      params = func[:params].collect{|name, type| Register.name(name, typeof(type)) }
      rtn_type = typeof(func[:return_type])
      Instruction.func_decl(name: func_id, params: params, return_type: rtn_type)
    end

    def function_begin(func_id, func, block)
      instrs = []
      if func[:return_type] != "void"
        rtn_type = typeof(func[:return_type])
        rtn_reg = Register.name("_retval_", rtn_type + "*")
        instrs << Instruction.alloca(type: rtn_type, target: rtn_reg)
      end
      func[:params].each do |name, type|
        param_type = typeof(type)
        target = Register.name("_P_#{name}", param_type + "*")
        instrs << Instruction.alloca(type: param_type, target: target)
        instrs << Instruction.store(source: Register.name(name, param_type), target: target)
      end
      func[:locals].each do |name, type|
        local_type = typeof(type)
        instrs << Instruction.alloca(type: local_type, target: Register.name(name, local_type + "*"))
      end
      instrs
    end

    def function_end(func_id, func, block)
      instrs = []
      if func[:return_type] == "void"
        instrs << Instruction.ret(source: nil, void: true)
      else
        rtn_type = typeof(func[:return_type])
        rtn_reg = Register.name("_retval_", rtn_type + "*")
        target = Register.alloc(rtn_type)
        instrs << Instruction.load(source: rtn_reg, target: target)
        instrs << Instruction.ret(source: target)
      end
      instrs
    end

    def next_block(block)
      if block.successors.any?
        Instruction.branch(cond: nil, true_label: block.successors[0][:block].label, false_label: nil, no_cond: true)
      end
    end

    def generate(func_id, block, statement)
      case statement[:stmt]
      when "assign"
        generate_assign(func_id, block, statement)
      when "print"
        generate_print(func_id, block, statement)
      when "delete"
        generate_delete(func_id, block, statement)
      when "return"
        generate_return(func_id, block, statement)
      when "invocation"
        generate_invocation(func_id, block, statement)
      when "branch"
        generate_branch(func_id, block, statement)
      else
        raise TranslationError.new("'#{statement[:stmt]}' cannot be translated into llvm instructions", statement)
      end
    end

    def defs_to_s
      # Noop for compatibility with ssa-translator
      ""
    end

    def attempt_seal(block)
      # Noop for compatibility with ssa-translator
      nil
    end

    def seal_blocks(graph)
      # Noop for compatibility with ssa-translator
      nil
    end

    def remove_trivial_phis(graph)
      # Noop for compatibility with ssa-translator
      nil
    end


    def reorder_phis(graph)
      # Noop for compatibility with ssa-translator
      nil
    end

    private

    def generate_assign(func_id, block, stmt)
      instrs = []
      if stmt[:source][:exp] == "read"
        target_type, target_reg, target_instrs = resolve_left(func_id, stmt[:target])
        instrs += target_instrs
        instrs << Instruction.read(target: target_reg)
      else
        source_reg, source_instrs = generate_expr(func_id, stmt[:source])
        instrs += source_instrs
        target_type, target_reg, target_instrs = resolve_left(func_id, stmt[:target])
        instrs += target_instrs
        if source_reg.immediate == "null"
          source_reg.type = typeof(target_type)
        end
        instrs << Instruction.store(source: source_reg, target: target_reg)
      end
      instrs
    end

    def generate_print(func_id, block, statement)
      instrs = []
      source_reg, source_instrs = generate_expr(func_id, statement[:exp])
      instrs += source_instrs
      instrs << Instruction.print(source: source_reg, endl: statement[:endl])
      instrs
    end

    def generate_delete(func_id, block, statement)
      instrs = []
      source_reg, source_instrs = generate_expr(func_id, statement[:exp])
      instrs += source_instrs
      target_reg = Register.alloc("i8*")
      instrs << Instruction.bitcast(source: source_reg, target: target_reg)
      instrs << Instruction.free(source: target_reg)
      instrs
    end

    def generate_return(func_id, block, statement)
      instrs = []
      if statement[:exp]
        source_reg, source_instrs = generate_expr(func_id, statement[:exp])
        instrs += source_instrs
        rtn_type = typeof(@function_table[func_id][:return_type])
        if source_reg.immediate == "null"
          source_reg.type = rtn_type
        end
        rtn_type += "*"
        rtn_reg = Register.name("_retval_", rtn_type)
        instrs << Instruction.store(source: source_reg, target: rtn_reg)
      end
      instrs
    end

    def generate_invocation(func_id, block, statement)
      instrs = []
      arg_regs = []
      @function_table[statement[:id]] or raise TranslationError.new("cannot invoke undefined function '#{statement[:id]}'", statement)
      statement[:args].each_with_index do |arg, ndx|
        reg, arg_instrs = generate_expr(func_id, arg)
        if reg.immediate == "null"
          func = @function_table[exp[:id]]
          reg.type = typeof(func[:params][func[:params].keys[ndx]])
        end
        arg_regs << reg
        instrs += arg_instrs
      end
      return_type = @function_table[statement[:id]][:return_type]
      return_type = typeof(return_type)
      instrs << Instruction.invocation(name: "#{statement[:id]}", args: arg_regs, target: nil, statement: true, return_type: return_type)
      instrs
    end

    def generate_branch(func_id, block, statement)
      instrs = []
      guard_reg, guard_instrs = generate_expr(func_id, statement[:guard])
      instrs += guard_instrs
      cond_reg = Register.alloc("i1")
      instrs << Instruction.truncate(source: guard_reg, target: cond_reg)
      true_label = block.successors.find {|s| s[:label] == :true }[:block].label
      false_label = block.successors.find {|s| s[:label] == :false }[:block].label
      instrs << Instruction.branch(cond: cond_reg, true_label: true_label, false_label: false_label)
      instrs
    end

    def generate_expr(func_id, exp)
      case exp[:exp]
      when "num"
        target_reg = Register.immediate(exp[:value])
        [target_reg, []]
      when "true"
        target_reg = Register.immediate("1")
        [target_reg, []]
      when "false"
        target_reg = Register.immediate("0")
        [target_reg, []]
      when "null"
        target_reg = Register.immediate("null")
        [target_reg, []]
      when "unary"
        generate_unary_expr(func_id, exp)
      when "new"
        generate_new_expr(func_id, exp)
      when "binary"
        generate_binary_expr(func_id, exp)
      when "dot"
        generate_dot_expr(func_id, exp)
      when "invocation"
        generate_invoc_expr(func_id, exp)
      else
        if exp[:id]
          target_reg, lookup_instrs = lookup_load(func_id, exp[:id])
          [target_reg, lookup_instrs]
        else
          raise TranslationError.new("'#{exp[:exp]}' cannot be translated into llvm instructions", exp)
        end
      end
    end

    def generate_new_expr(func_id, exp)
      instrs = []
      tmp_reg = Register.alloc("i8*")
      target_reg = Register.alloc(typeof(exp[:id]))
      num_fields = @struct_table[exp[:id]][:fields].size

      instrs << Instruction.malloc(size: num_fields * 4, target: tmp_reg)
      instrs << Instruction.bitcast(source: tmp_reg, target: target_reg)
      [target_reg, instrs]
    end

    def generate_unary_expr(func_id, exp)
      instrs = []
      source_reg, source_instrs = generate_expr(func_id, exp[:operand])
      instrs += source_instrs
      case exp[:operator]
      when "-"
        zero_reg = Register.new(name: nil, type: "i32", immediate: "0")
        target_reg = Register.alloc("i32")
        instrs << Instruction.arith(op: "-", left: zero_reg, right: source_reg, target: target_reg)
        [target_reg, instrs]
      when "!"
        one_reg = Register.new(name: nil, type: "i32", immediate: "1")
        target_reg = Register.alloc("i32")
        instrs << Instruction.xor(left: one_reg, right: source_reg, target: target_reg)
        [target_reg, instrs]
      else
        raise TranslationError.new("invalid unary expression operator '#{exp[:operator]}'", exp)
      end
    end

    def generate_binary_expr(func_id, exp)
      instrs = []
      left_reg, left_instrs = generate_expr(func_id, exp[:lft])
      right_reg, right_instrs = generate_expr(func_id, exp[:rht])
      instrs += left_instrs + right_instrs
      if ["+", "-", "*", "/"].include? exp[:operator]
        result_reg, op_instrs = generate_arith_expr(exp[:operator], left_reg, right_reg)
      elsif ["&&", "||"].include? exp[:operator]
        result_reg, op_instrs = generate_logic_expr(exp[:operator], left_reg, right_reg)
      else
        result_reg, op_instrs = generate_compare_expr(exp[:operator], left_reg, right_reg)
      end
      [result_reg, instrs + op_instrs]
    end

    def generate_arith_expr(op, left_reg, right_reg)
      target_reg = Register.alloc("i32")
      instr = Instruction.arith(op: op, left: left_reg, right: right_reg, target: target_reg)
      [target_reg, [instr]]
    end

    def generate_logic_expr(op, left_reg, right_reg)
      target_reg = Register.alloc("i32")
      if op == "&&"
        instr = Instruction.and(left: left_reg, right: right_reg, target: target_reg)
      else
        instr = Instruction.or(left: left_reg, right: right_reg, target: target_reg)
      end
      [target_reg, [instr]]
    end

    def generate_compare_expr(op, left_reg, right_reg)
      instrs = []
      if left_reg.immediate == "null"
        left_reg.type = right_reg.type
      elsif right_reg == "null"
        right_reg.type = left_reg.type
      end
      tmp_reg = Register.alloc("i1")
      instrs << Instruction.icmp(cond: op, left: left_reg, right: right_reg, target: tmp_reg)
      target_reg = Register.alloc("i32")
      instrs << Instruction.zext(source: tmp_reg, target: target_reg)
      [target_reg, instrs]
    end

    def generate_dot_expr(func_id, exp)
      instrs = []
      source_type, source_reg, source_instrs = resolve_left(func_id, exp)
      instrs += source_instrs
      target_reg = Register.alloc(typeof(source_type))
      instrs << Instruction.load(source: source_reg, target: target_reg)
      [target_reg, instrs]
    end

    def generate_invoc_expr(func_id, exp)
      instrs = []
      arg_regs = []
      @function_table[exp[:id]] or raise TranslationError.new("cannot invoke undefined function '#{exp[:id]}'", exp)
      exp[:args].each_with_index do |arg, ndx|
        reg, arg_instrs = generate_expr(func_id, arg)
        if reg.immediate == "null"
          func = @function_table[exp[:id]]
          reg.type = typeof(func[:params][func[:params].keys[ndx]])
        end
        arg_regs << reg
        instrs += arg_instrs
      end
      return_type = @function_table[exp[:id]][:return_type]
      if return_type == "void"
        instrs << Instruction.invocation(name: "#{exp[:id]}", args: arg_regs, target: nil, void: true)
      else
        target_reg = Register.alloc(typeof(return_type))
        instrs << Instruction.invocation(name: "#{exp[:id]}", args: arg_regs, target: target_reg)
      end
      [target_reg, instrs]
    end

    def resolve_left(func_id, exp)
      instrs = []
      if exp[:left]
        left_type, left_reg, left_instrs = resolve_left(func_id, exp[:left])
        instrs += left_instrs
        orig_type, target_reg, lookup_instrs = lookup_in_reg(func_id, left_type, left_reg, exp[:id])
        instrs += lookup_instrs
        [orig_type, target_reg, instrs]
      elsif exp[:exp] == "invocation"
        orig_type = @function_table[exp[:id]][:return_type]
        left_reg, left_instrs = generate_invoc_expr(func_id, exp)
        instrs += left_instrs
        [orig_type, left_reg, instrs]
      else
        type, reg = lookup(func_id, exp[:id])
        reg.type += "*"
        [type, reg, []]
      end
    end

    def lookup_load(func_id, id)
      orig_type, source_reg = lookup(func_id, id)
      source_reg.type += "*"
      target_reg = Register.alloc(typeof(orig_type))
      [target_reg, [Instruction.load(source: source_reg, target: target_reg)]]
    end

    def lookup(func_id, id)
      if @function_table[func_id][:locals][id]
        orig_type = @function_table[func_id][:locals][id]
        reg = Register.name(id, typeof(orig_type))
      elsif @function_table[func_id][:params][id]
        orig_type = @function_table[func_id][:params][id]
        type = typeof(orig_type)
        reg = Register.name("_P_#{id}", type)
      elsif @global_table[id]
        orig_type = @global_table[id][:type]
        reg = Register.name(id, typeof(orig_type))
        reg.global = true
      else
        raise CFGError.new("could not find identifier '#{id}'", id)
      end
      [orig_type, reg]
    end

    def lookup_in_struct(func_id, left, id)
      instrs = []
      id and left or raise TranslationError.new("cannot resolve '#{id}' in '#{left}'", exp)
      if left[:left]
        orig_type, base_reg, base_instrs = lookup_in_struct(func_id, left[:left], left[:id])
        instrs += base_instrs
      else
        orig_type, base_reg = lookup(func_id, left[:id])
        unless ["int", "bool"].include? orig_type
          base_reg.type += "*"
        end
      end
      source = Register.name(left[:id], base_reg.type)
      tmp_reg = Register.alloc(typeof(orig_type))
      instrs << Instruction.load(source: source, target: tmp_reg)
      target_type = @struct_table[orig_type][:fields][id] or raise TranslationError.new("cannot find '#{id}' in '#{orig_type}'", nil)
      index = @struct_table[orig_type][:fields].find_index {|f,_| f == id}
      target = Register.alloc(typeof(target_type) + "*")
      instrs << Instruction.getelemptr(source: tmp_reg, index: index, target: target)
      [target_type, target, instrs]
    end

    def lookup_in_reg(func_id, base_type, base_reg, id)
      instrs = []
      if level_of_indirection(base_reg.type) > 1
        tmp_reg = Register.alloc(typeof(base_type))
        instrs << Instruction.load(source: base_reg, target: tmp_reg)
      else
        tmp_reg = base_reg
      end
      target_type = @struct_table[base_type][:fields][id] or raise TranslationError.new("cannot find '#{id}' in '#{base_type}'", nil)
      index = @struct_table[base_type][:fields].find_index {|f,_| f == id}
      target_reg = Register.alloc(typeof(target_type) + "*")
      instrs << Instruction.getelemptr(source: tmp_reg, index: index, target: target_reg)
      [target_type, target_reg, instrs]
    end

    def level_of_indirection(type)
      result = type.match(/%struct\.\w*(\**)/)[1]
      if result.nil?
        0
      else
        result.size
      end
    end
  end
end
