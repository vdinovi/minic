module Minic::LLVM
  Var = Struct.new(:id, :type, :base) do
    def to_s
      suffix = type == :id ? "id" : "dot"
      "#{id}_#{suffix}"
    end
  end

  class SSATranslator
    include Minic::Errors

    def initialize(struct_table, global_table, function_table)
      @struct_table = struct_table
      @global_table = global_table
      @function_table = function_table
      @defs = {}
      @incomplete_phis = {}
      @sealed = Set[]
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

    def struct_declaration(name, type)
      fields = type[:fields].collect {|_, f| typeof(f)}
      [Instruction.struct_decl(name: name, fields: fields)]
    end

    def global_declaration(name, type)
      target_reg = Register.name(name, typeof(type[:type]))
      target_reg.immediate = ["int", "bool"].member?(type[:type]) ? "0" : "null"
      target_reg.global = true
      [Instruction.global_decl(target: target_reg)]
    end

    def func_declaration(func_id, func)
      params = func[:params].collect{|name, type| Register.name(name, typeof(type)) }
      rtn_type = typeof(func[:return_type])
      Instruction.func_decl(name: func_id, params: params, return_type: rtn_type)
    end

    def function_begin(func_id, func, block)
      func[:params].each do |name, type|
        write_var(Var.new(name, :id), block, Register.name(name, typeof(type)))
      end
      func[:locals].each do |name, type|
        write_var(Var.new(name, :id), block, Register.immediate(0))
      end
      []
    end

    def function_end(func_id, func, block)
      if func[:return_type] == "void"
        instrs = [Instruction.ret(source: nil, void: true)]
      else
        reg, instrs = read_var(Var.new("_retval_", :id), block)
        instrs << Instruction.ret(source: reg)
        reg.uses << instrs.last
      end
      instrs
    end

    def next_block(block)
      if block.successors.any?
        Instruction.branch(cond: nil, true_label: block.successors[0][:block].label, false_label: nil, no_cond: true)
      end
      #@sealed << block if block.predecessors.all? {|pred| @sealed.member?(pred)}
    end

    def defs_to_s
      accum = ""
      @defs.each do |var, blocks|
        accum << "#{var}: #{blocks.collect {|block, value| "#{block.label}=#{value.immediate ? value.immediate : value.name}"}.join(", ")}\n"
      end
      accum
    end

    def attempt_seal(block)
      seal(block) if block.predecessors.all? {|pred| @sealed.member?(pred)}
    end

    def seal_blocks(graph)
      graph.blocks.each do |block|
        seal(block)
      end
    end

    def remove_trivial(phi)
      phi.body[:trivial] = true
      phi_reg = phi.body[:target_reg]
      source = phi.body[:source_regs].first
      phi.body[:target_reg].uses.each do |use|
        use.body[:source_reg] = source and source.uses << use if use.body[:source_reg] == phi_reg
        use.body[:left_reg] = source and source.uses << use if use.body[:left_reg] == phi_reg
        use.body[:right_reg] = source and source.uses << use if use.body[:right_reg] == phi_reg
        use.body[:cond_reg] = source and source.uses << use if use.body[:cond_reg] == phi_reg
        if use.body[:arg_regs]
          use.body[:arg_regs].each_with_index do |_, index|
            use.body[:arg_regs][index] = source and source.uses << use if use.body[:arg_regs][index] == phi_reg
          end
        end
        if use.body[:source_regs]
          use.body[:source_regs].each_with_index do |_, index|
            use.body[:source_regs][index] = source and source.uses << use if use.body[:source_regs][index] == phi_reg
          end
        end
      end
    end

    def split_trivial(phis)
      trivial = []
      workset = []
      phis.each do |phi|
        if !phi.body[:trival] && phi.body[:source_regs].size == 1
          trivial << phi
        elsif !phi.body[:trival] && phi.body[:source_regs].uniq.size == 1
          trivial << phi
        else
          workset << phi
        end
      end
      [trivial, workset]
    end

    def remove_trivial_phis(graph)
      phis = []
      graph.blocks.each do |block|
        phis += block.llvm.select {|instr| instr.opcode == :phi}
      end

      trivial, work_set = split_trivial(phis)
      while trivial.any?
        trivial.each do |phi|
          remove_trivial(phi)
        end
        trivial, work_set = split_trivial(work_set)
      end
    end

    def reorder_phis(graph)
      graph.blocks.each do |block|
        phis = block.llvm.select {|instr| instr.opcode == :phi}
        phis.each do |phi|
          block.llvm.delete(phi)
          block.llvm.unshift(phi)
        end
      end
    end

    private

    def create_var(expr)
      if expr[:left]
        Var.new(expr[:id], :dot, create_var(expr[:left]))
      else
        Var.new(expr[:id], :id)
      end
    end

    def write_var(var, block, val)
      @defs[var] = {} unless @defs[var]
      @defs[var][block] = val
      if var.type == :dot
        write_dot(var, block, val)
      else
        []
      end
    end

    def write_dot(var, block, val)
      target_reg, instrs = resolve_dot(var, block)
      instrs << Instruction.store(source: val, target: target_reg)
      target_reg.defined = instrs.last
      val.uses << instrs.last
      instrs
    end

    def resolve_dot(var, block, ld=false)
      if var.base.type == :id && is_global?(block.func_id, var.base.id)
        type = typeof(@global_table[var.base.id][:type])
        global_reg = Register.name(var.base.id, type + "*")
        global_reg.global = true
        base_reg = Register.alloc(type)
        instrs = [Instruction.load(source: global_reg, target: base_reg)]
      else
        base_reg, instrs = read_var(var.base, block)
      end
      base_type = base_reg.type || lookup_type(block.func_id, var.base)
      struct_type = /%struct.([A-z][A-z0-9]*)\*/.match(base_type) or raise "Couldn't parse a valid struct name from #{base_reg.type or 'nil'}"
      struct_type = struct_type[1]
      index = @struct_table[struct_type][:fields].keys.index(var.id) or raise "Couldn't find valid struct for '#{struct_type}'"
      target_reg = Register.alloc(typeof(@struct_table[struct_type][:fields][var.id]) + "*")
      instrs << Instruction.getelemptr(source: base_reg, index: index, target: target_reg)
      target_reg.defined = instrs.last
      base_reg.uses << instrs.last
      if ld
        source_reg = target_reg
        target_reg = Register.alloc(typeof(@struct_table[struct_type][:fields][var.id]))
        instrs << Instruction.load(source: source_reg, target: target_reg)
        target_reg.defined = instrs.last
        source_reg.uses << instrs.last
      end
      [target_reg, instrs]
    end

    def lookup_type(func_id, var)
      if var.type == :id
        if @function_table[func_id][:locals].keys.member? var.id
          typeof(@function_table[func_id][:locals].find {|name, type| name == var.id}[1])
        elsif @function_table[func_id][:params].keys.member? var.id
          typeof(@function_table[func_id][:params].find {|name, type| name == var.id}[1])
        elsif is_global?(func_id, var.id)
          typeof(@global_table[var.id][:type])
        else
          raise "could not find variable #{var.id}"
        end
      else
        base_type = lookup_type(func_id, var.base)
        struct_type = /%struct.([A-z][A-z0-9]*)\*/.match(base_type) or raise "Couldn't parse a valid struct name from #{base_reg.type or 'nil'}"
        struct_type = struct_type[1]
        typeof(@struct_table[struct_type][:fields].find {|name, type| name == var.id}[1])
      end
    end

    def read_var(var, block)
      if var.type == :dot
        resolve_dot(var, block, true)
      elsif @defs[var] && @defs[var].key?(block)
        [@defs[var][block], []]
      else
        read_var_from_pred(var, block)
      end
    end

    def read_var_from_pred(var, block)
      instrs = []
      if !@sealed.member?(block.label)
        reg = Register.phi
        phi = Instruction.phi(sources: [], labels: [], target: reg)
        reg.defined = phi
        phi.body[:block] = block
        block.llvm.unshift(phi)
        @incomplete_phis[block] = {} unless @incomplete_phis[block]
        @incomplete_phis[block][var] = phi
      elsif block.predecessors.size == 0
        reg = nil
      elsif block.predecessors.size == 1
        reg, instrs = read_var(var, block.predecessors[0])
      else
        reg = Register.phi
        phi = Instruction.phi(sources: [], labels: [], target: reg)
        reg.defined = phi
        phi.body[:block] = block
        block.llvm.unshift(phi)
        instrs += write_var(var, block, reg)
        write_var(var, phi.body[:block], phi.body[:target_reg])
        add_phi_operands(var, phi)
      end
      instrs += write_var(var, block, reg)
      [reg, instrs]
    end

    def read_global(var)
      if @defs[var] && @defs[var]["global"]
        instrs = []
        global_reg = @defs[var]["global"]
        target_reg = Register.alloc(global_reg.type)
        instrs << Instruction.load(source: global_reg, target: target_reg)
        [target_reg, instrs]
      else
        [nil, []]
      end
    end

    def add_phi_operands(var, phi)
      phi.body[:block].predecessors.each do |pred|
        reg, instrs = read_var(var, pred)
        pred.llvm = instrs + pred.llvm
        phi.body[:source_regs].push(reg)
        phi.body[:source_labels].push(pred.label)
        phi.body[:target_reg].type = reg.type unless phi.body[:target_reg].type
        phi.body[:target_reg].defined = phi
        reg.uses << phi
      end
    end

    def seal(block)
      if @incomplete_phis[block]
        @incomplete_phis[block].each do |var, phi|
          add_phi_operands(var, phi)
          phi.body[:target_reg].type = lookup_type(block.func_id, var) unless phi.body[:target_reg].type
        end
      end
      @sealed << block.label
    end

    def generate_assign(func_id, block, stmt)
      source_reg, instrs = generate_expr(func_id, block, stmt[:source])
      var = create_var(stmt[:target])
      source_reg.type = lookup_type(func_id, var) if !source_reg.type && source_reg.immediate == "null"
      if !stmt[:target][:left] && is_global?(func_id, stmt[:target][:id])
        type = typeof(@global_table[stmt[:target][:id]][:type])
        global_reg = Register.name(stmt[:target][:id], type + "*")
        global_reg.global = true
        target_reg = Register.alloc(type)
        instrs << Instruction.store(source: source_reg, target: global_reg)
        target_reg.defined = instrs.last
        source_reg.uses << instrs.last
      else
        instrs += write_var(var, block, source_reg)
      end
      instrs
    end

    def generate_print(func_id, block, statement)
      source_reg, instrs = generate_expr(func_id, block, statement[:exp])
      instrs << Instruction.print(source: source_reg, endl: statement[:endl])
      source_reg.uses << instrs.last
      instrs
    end

    def generate_delete(func_id, block, statement)
      source_reg, instrs = generate_expr(func_id, block, statement[:exp])
      target_reg = Register.alloc("i8*")
      instrs << Instruction.bitcast(source: source_reg, target: target_reg)
      source_reg.uses << instrs.last
      source_reg.defined = instrs.last

      instrs << Instruction.free(source: target_reg)
      target_reg.uses << instrs.last
      instrs
    end

    def generate_return(func_id, block, statement)
      if statement[:exp]
        source_reg, instrs = generate_expr(func_id, block, statement[:exp])
        source_reg.type = typeof(@function_table[func_id][:return_type])
        instrs += write_var(Var.new("_retval_", :id), block, source_reg)
        instrs
      else
        []
      end
    end

    def generate_invocation(func_id, block, statement)
      instrs = []
      arg_regs = []
      @function_table[statement[:id]] or raise TranslationError.new("cannot invoke undefined function '#{statement[:id]}'", statement)
      statement[:args].each_with_index do |arg, ndx|
        reg, arg_instrs = generate_expr(func_id, block, arg)
        if reg.immediate == "null"
          func = @function_table[func_id]
          reg.type = typeof(func[:params][func[:params].keys[ndx]])
        end
        arg_regs << reg
        instrs += arg_instrs
      end
      return_type = @function_table[statement[:id]][:return_type]
      return_type = typeof(return_type)
      instrs << Instruction.invocation(name: "#{statement[:id]}", args: arg_regs, target: nil, statement: true, return_type: return_type)
      arg_regs.each {|reg| reg.uses << instrs.last}
      instrs
    end

    def generate_branch(func_id, block, statement)
      guard_reg, instrs = generate_expr(func_id, block, statement[:guard])
      cond_reg = Register.alloc("i1")
      instrs << Instruction.truncate(source: guard_reg, target: cond_reg)
      guard_reg.uses << instrs.last
      cond_reg.defined = instrs.last

      true_label = block.successors.find {|s| s[:label] == :true }[:block].label
      false_label = block.successors.find {|s| s[:label] == :false }[:block].label
      instrs << Instruction.branch(cond: cond_reg, true_label: true_label, false_label: false_label)
      cond_reg.uses << instrs.last
      instrs
    end

    def generate_expr(func_id, block, exp)
      instrs = []
      case exp[:exp]
      when "num"
        target_reg = Register.immediate(exp[:value])
      when "true"
        target_reg = Register.immediate("1")
      when "false"
        target_reg = Register.immediate("0")
      when "null"
        target_reg = Register.immediate("null", nil)
      when "read"
        target_reg, instrs = generate_read_expr(func_id, block)
      when "unary"
        target_reg, instrs = generate_unary_expr(func_id, block,  exp)
      when "new"
        target_reg, instrs = generate_new_expr(func_id, block,  exp)
      when "binary"
        target_reg, instrs = generate_binary_expr(func_id, block, exp)
      when "dot"
        target_reg, instrs = generate_dot_expr(func_id, block,  exp)
      when "invocation"
        target_reg, instrs = generate_invoc_expr(func_id, block, exp)
      else
        if exp[:id]
          if is_global?(func_id, exp[:id])
            type = typeof(@global_table[exp[:id]][:type])
            global_reg = Register.name(exp[:id], type + "*")
            global_reg.global = true
            target_reg = Register.alloc(type)
            instrs << Instruction.load(source: global_reg, target: target_reg)
          else
            var = Var.new(exp[:id], :id)
            target_reg, instrs = read_var(var, block)
          end
        else
          raise TranslationError.new("'#{exp[:exp]}' cannot be translated into llvm instructions", exp)
        end
      end
      [target_reg, instrs]
    end

    def generate_read_expr(func_id, block)
      instrs = []
      target_reg = Register.alloc("i32")
      read_scratch = Register.name(".read_scratch", "i32*")
      read_scratch.global = true
      instrs << Instruction.read(target: read_scratch)
      read_scratch.defined = instrs.last

      instrs << Instruction.load(target: target_reg, source: read_scratch)
      read_scratch.uses << instrs.last
      target_reg.defined = instrs.last

      [target_reg, instrs]
    end

    def generate_new_expr(func_id, block, exp)
      instrs = []
      tmp_reg = Register.alloc("i8*")
      target_reg = Register.alloc(typeof(exp[:id]))
      num_fields = @struct_table[exp[:id]][:fields].size
      instrs << Instruction.malloc(size: num_fields * 4, target: tmp_reg)
      tmp_reg.defined = instrs.last

      instrs << Instruction.bitcast(source: tmp_reg, target: target_reg)
      tmp_reg.uses = instrs.last
      target_reg.defined = instrs.last
      [target_reg, instrs]
    end

    def generate_unary_expr(func_id, block,  exp)
      source_reg, instrs = generate_expr(func_id, block,  exp[:operand])
      case exp[:operator]
      when "-"
        zero_reg = Register.new(name: nil, type: "i32", immediate: "0")
        target_reg = Register.alloc("i32")
        instrs << Instruction.arith(op: "-", left: zero_reg, right: source_reg, target: target_reg)
        zero_reg.uses << instrs.last
        source_reg.uses << instrs.last
        target_reg.defined = instrs.last
        [target_reg, instrs]
      when "!"
        one_reg = Register.new(name: nil, type: "i32", immediate: "1")
        target_reg = Register.alloc("i32")
        instrs << Instruction.xor(left: one_reg, right: source_reg, target: target_reg)
        one_reg.uses << instrs.last
        source_reg.uses << instrs.last
        target_reg.defined = instrs.last
        [target_reg, instrs]
      else
        raise TranslationError.new("invalid unary expression operator '#{exp[:operator]}'", exp)
      end
    end

    def generate_binary_expr(func_id, block, exp)
      instrs = []
      left_reg, left_instrs = generate_expr(func_id, block, exp[:lft])
      right_reg, right_instrs = generate_expr(func_id, block, exp[:rht])
      instrs += left_instrs + right_instrs
      if ["+", "-", "*", "/"].include? exp[:operator]
        result_reg, op_instrs = generate_arith_expr(block, exp[:operator], left_reg, right_reg)
      elsif ["&&", "||"].include? exp[:operator]
        result_reg, op_instrs = generate_logic_expr(block, exp[:operator], left_reg, right_reg)
      else
        result_reg, op_instrs = generate_compare_expr(block, exp[:operator], left_reg, right_reg)
      end
      instrs += op_instrs
      [result_reg, instrs]
    end

    def generate_arith_expr(block, op, left_reg, right_reg)
      target_reg = Register.alloc("i32")
      instrs = [Instruction.arith(op: op, left: left_reg, right: right_reg, target: target_reg)]
      left_reg.uses << instrs.last
      right_reg.uses << instrs.last
      target_reg.defined = instrs.last
      [target_reg, instrs]
    end

    def generate_logic_expr(block, op, left_reg, right_reg)
      target_reg = Register.alloc("i32")
      if op == "&&"
        instrs = [Instruction.and(left: left_reg, right: right_reg, target: target_reg)]
      else
        instrs = [Instruction.or(left: left_reg, right: right_reg, target: target_reg)]
      end
      left_reg.uses << instrs.last
      right_reg.uses << instrs.last
      target_reg.defined = instrs.last
      [target_reg, instrs]
    end

    def generate_compare_expr(block, op, left_reg, right_reg)
      instrs = []
      if left_reg.immediate == "null"
        left_reg.type = right_reg.type
      elsif right_reg == "null"
        right_reg.type = left_reg.type
      end
      tmp_reg = Register.alloc("i1")
      instrs << Instruction.icmp(cond: op, left: left_reg, right: right_reg, target: tmp_reg)
      left_reg.uses << instrs.last
      right_reg.uses << instrs.last
      tmp_reg.defined = instrs.last

      target_reg = Register.alloc("i32")
      instrs << Instruction.zext(source: tmp_reg, target: target_reg)
      tmp_reg.uses << instrs.last
      target_reg.defined = instrs.last
      [target_reg, instrs]
    end

    def create_var_dot(exp)
      if exp[:exp] == "dot"
        base, instrs = create_var_dot(exp[:left])
        [Var.new(exp[:id], :dot, base), instrs]
      else
        [Var.new(exp[:id], :id), []]
      end
    end

    def generate_dot_expr(func_id, block, exp)
      if exp[:exp] == "dot" && exp[:left][:exp] == "invocation"
        generate_invoc_deref(func_id, block, exp)
      else
        var, instrs = create_var_dot(exp)
        reg, r_instrs = read_var(var, block)
        instrs += r_instrs
        [reg, instrs]
      end
    end

    def generate_invoc_deref(func_id, block, exp)
      base_reg, instrs = generate_invoc_expr(func_id, block, exp[:left])
      struct_type = /%struct.([A-z][A-z0-9]*)\*/.match(base_reg.type)[1] or raise "Couldn't parse a valid struct name from #{base_reg.type}"
      index = @struct_table[struct_type][:fields].keys.index(exp[:id]) or raise "Couldn't find valid struct for #{struct_type}"
      target_reg = Register.alloc(typeof(@struct_table[struct_type][:fields][exp[:id]]) + "*")
      instrs << Instruction.getelemptr(source: base_reg, index: index, target: target_reg)
      target_reg.defined = instrs.last
      base_reg.uses << instrs.last
      source_reg = target_reg
      target_reg = Register.alloc(typeof(@struct_table[struct_type][:fields][exp[:id]]))
      instrs << Instruction.load(source: source_reg, target: target_reg)
      target_reg.defined = instrs.last
      source_reg.uses << instrs.last
      [target_reg, instrs]
    end

    def generate_invoc_expr(func_id, block, exp)
      instrs = []
      arg_regs = []
      @function_table[exp[:id]] or raise TranslationError.new("cannot invoke undefined function '#{exp[:id]}'", exp)
      exp[:args].each_with_index do |arg, ndx|
        reg, arg_instrs = generate_expr(func_id, block, arg)
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
        target_reg = nil
      else
        target_reg = Register.alloc(typeof(return_type))
        instrs << Instruction.invocation(name: "#{exp[:id]}", args: arg_regs, target: target_reg)
        target_reg.defined = instrs.last
      end
      arg_regs.each {|reg| reg.uses << instrs.last}
      [target_reg, instrs]
    end

    def is_global?(func_id, id)
      !@function_table[func_id][:params].keys.member?(id) && !@function_table[func_id][:locals].keys.member?(id) && @global_table[id]
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
  end
end
