require 'minic/llvm'

module Minic::ARM
  class Translator
    include Minic::Errors

    SPILL_REGS = [Register.phys_reg("r9"), Register.phys_reg("r10")]

    def initialize(struct_table, global_table, function_table)
      @@labels = 0
      @struct_table = struct_table
      @global_table = global_table
      @function_table = function_table
      @phis = Set[]
    end

    def get_label
      num = @@labels
      @@labels += 1
      "label_#{num}"
    end

    def setup_arm_function(name, graph)
      graph.pre = [
        Instruction.directive(name: "align", args: ["2"]),
        Instruction.directive(name: "global", args: [name]),
        Instruction.directive(name: "syntax", args: ["unified"]),
        Instruction.directive(name: "type", args: [name, "%function"])
      ]
      graph.entry.arm << Instruction.label(name: name)
      # Push fp, lr
      graph.entry.arm << graph.stack.push(["fp", "lr"].map {|r| Register.phys_reg(r)})
      graph.entry.arm << Instruction.add(dest: Register.phys_reg("fp"), srcs: [Register.phys_reg("sp"), Register.reg(4)])
      # Alloc params, locals, caller-saved regs
      allocs = graph.entry.llvm.collect {|i| Register.reg(i.body[:target_reg].name) if i.opcode == :alloca}.compact
      calls = graph.blocks.map {|b| b.llvm.select {|i| i.opcode == :invocation}}.flatten.map {|call| call.body[:name]}
      caller_saved_regs = (0..3).to_a.map {|i| Register.reg("crr#{i}")}
      graph.entry.arm << graph.stack.alloc(allocs + caller_saved_regs)
      graph.entry.arm << Instruction.placeholder(label: "alloc_spill")
      graph.entry.arm << Instruction.placeholder(label: "push_callee_save")
      graph.entry.arm << Instruction.placeholder(label: "alloc_arg_space")
      # Copy args
      @function_table[name][:params].keys.each_with_index do |param, index|
        param_reg = Register.reg(param)
        if index < 4
          graph.entry.arm << Instruction.mov(dest: param_reg, srcs: [Register.phys_reg("r#{index}")])
        else
          graph.entry.arm << Instruction.load(dest: param_reg, srcs: [Register.phys_reg("fp")], pre: {size: (index - 3) * 4, update: false})
        end
      end
    end

    def close_arm_function(name, graph)
      graph.exit.arm << Instruction.placeholder(label: "free_arg_space")
      graph.exit.arm << Instruction.placeholder(label: "pop_callee_save")
      graph.exit.arm << Instruction.placeholder(label: "free_spill")
      graph.exit.arm << graph.stack.dealloc_to("lr")
      graph.exit.arm << graph.stack.pop(["fp", "pc"].map {|r| Register.phys_reg(r)})
      graph.post = [ Instruction.directive(name: "size", args: [name, ".-#{name}"]) ]
      @phis.each {|phi| generate_phi(phi)}
      @phis.clear
    end

    def callee_save(graph)
      # push callee-saved registers
      killed = graph.blocks.map {|b| b.killed}.reduce {|ks, s| ks | s}
      killed &= (4..8).to_a.map {|i| Register.phys_reg("r#{i}")}.to_set
      index = graph.entry.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "push_callee_save"}
      if killed.any?
        graph.entry.arm[index] = Instruction.push(srcs: killed.to_a)
      else
        graph.entry.arm.delete_at(index)
      end
      # pop callee-saved registers
      index = graph.exit.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "pop_callee_save"}
      if killed.any?
        graph.exit.arm[index] = Instruction.pop(dests: killed.to_a)
      else
        graph.exit.arm.delete_at(index)
      end
    end

    def arg_space(graph)
      # alloc arg space
      calls = graph.blocks.map {|b| b.llvm.select {|i| i.opcode == :invocation}}.flatten.map {|call| call.body[:name]}
      max_args = calls.map {|fname| @function_table[fname][:params].size}.max || 0
      index = graph.entry.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "alloc_arg_space"}
      if max_args > 4
        graph.entry.arm[index] = Instruction.sub(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg((max_args - 4) * 4)])
      else
        graph.entry.arm.delete_at(index)
      end
      # dealloc arg space
      index = graph.exit.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "free_arg_space"}
      if max_args > 4
        graph.exit.arm[index] = Instruction.add(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg((max_args - 4) * 4)])
      else
        graph.exit.arm.delete_at(index)
      end
    end

    def spill_space(graph)
      # alloc spill space
      spill_size = graph.stack.spills.size * 4
      index = graph.entry.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "alloc_spill"}
      if spill_size > 0
        graph.entry.arm[index] = Instruction.sub(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(spill_size)])
      else
        graph.entry.arm.delete_at(index)
      end
      # free spill space
      index = graph.exit.arm.find_index {|i| i.opcode == :placeholder && i.body[:label] == "free_spill"}
      if spill_size > 0
        graph.exit.arm[index] = Instruction.add(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(spill_size)])
      else
        graph.exit.arm.delete_at(index)
      end
    end

    def insert_spill(graphs, reg)
      spill_key = "spill_" + reg.value
      graphs.each do |name, graph|
        occurs = graph.blocks.collect do |b|
          b.arm.select do |i|
            (i.body[:srcs] && i.body[:srcs].include?(reg)) ||
            (i.body[:dests] && i.body[:dests].include?(reg)) ||
            (i.body[:dest] && i.body[:dest] == reg)
          end
        end.flatten.size
        next if occurs < 1
        graph.stack.add_spill(spill_key)
        graph.blocks.each do |block|
          instrs = []
          block.arm.each_with_index do |arm, index|
            # find uses -> replace with load
            if arm.body[:srcs] && arm.body[:srcs].include?(reg)
              spill_reg = arm.body[:srcs].include?(SPILL_REGS[0]) ? SPILL_REGS[1] : SPILL_REGS[0]
              instrs << graph.stack.load_spill(spill_key, spill_reg)
              arm.body[:srcs] = arm.body[:srcs].map {|src| src == reg ? spill_reg : src }
            end
            # copy instr
            instrs << arm
            # find defs -> replace with store
            if arm.body[:dests] && arm.body[:dests].include?(reg)
              if arm.body[:dests].include?(SPILL_REGS[0]) && dests..include?(SPILL_REGS[1])
                raise "error pop dests already include both spill registers, cannot add a third"
              end
              spill_reg = arm.body[:dests].include?(SPILL_REGS[0]) ? SPILL_REGS[1] : SPILL_REGS[0]
              arm.body[:dests] = arm.body[:dests].map {|dest| dest == reg ? spill_reg : dest }
              instrs << graph.stack.store_spill(spill_key, spill_reg)
            elsif arm.body[:dest] == reg
              arm.body[:dest] = SPILL_REGS[0]
              instrs << graph.stack.store_spill(spill_key, SPILL_REGS[0])
            end
          end
          block.arm = instrs
        end
      end
    end

    def caller_save(range, stack)
      range.map {|index| stack.store("crr#{index}", Register.phys_reg("r#{index}"))}
    end

    def caller_restore(range, stack)
      range.map {|index| stack.load("crr#{index}", Register.phys_reg("r#{index}"))}
    end

    def generate(func_id, llvm, stack)
      b = llvm.body
      case llvm.opcode
      when :store
        generate_store(b[:target_reg], b[:source_reg], stack)
      when :load
        generate_load(b[:target_reg], b[:source_reg], stack)
      when :add, :sub, :mul, :sdiv
        generate_arith(llvm.opcode, b, stack)
      when :xor, :and, :or
        generate_logic(llvm.opcode, b)
      when :branch
        generate_branch(b)
      when :ret
        generate_ret(b)
      when :invocation
        generate_invocation(b, stack)
      when :icmp
        generate_compare(b)
      when :read
        generate_scanf(b, stack)
      when :print
        generate_printf(b, stack)
      when :malloc
        generate_malloc(b, stack)
      when :free
        generate_free(b, stack)
      when :getelementptr
        generate_deref(b)
      when :phi
        collect_phi(llvm)
      when :zext, :trunc, :bitcast
        mov_instr(b[:target_reg], b[:source_reg])
      when :alloca, :misc, :nyi, :struct_decl, :global_decl, :func_decl
        # throwaways
        []
      else
        raise "instruction with unknown opcode '#{@opcode}'"
      end
    end

    def mov_instr(dest, src)
      if is_immediate(src)
        value = convert_immediate src
        if value < 0 || value > 255
          [
            Instruction.movw(dest: Register.reg(dest), srcs: [Register.reg(value & 0x0000ffff)]),
            Instruction.movt(dest: Register.reg(dest), srcs: [Register.reg((value & 0xffff0000) >> 16)])
          ]
        else
          [Instruction.mov(dest: Register.reg(dest), srcs: [Register.reg(value)])]
        end
      else
        [Instruction.mov(dest: Register.reg(dest), srcs: [Register.reg(src)])]
      end
    end

    # TODO: currently no bounds-checking on immediate moves
    #       -- values > 16-bit 2's-compl cause compile error
    #       (this seemed like a fix that could be done later)
    def move_immediate(dest, value)
      instrs = []
      instrs << Instruction.movw(dest: Register.reg(dest), srcs: [Register.reg(value.to_i)])
      #instrs << Instruction.movw(dest: target, srcs: [Register.reg(value.to_i & 0x00FF)])
      # TODO ruby does not store FIXNUMS in 2's complement, instead unsigned with sign flag
      # Need to adjust this accordingly
      # if value < LO_BOUND_16 || value > UP_BOUND_16
      #  instrs << Instruction.movt(dest: target, srcs: [Register.reg(value >> 15)])
      #end
      instrs
    end

    # TODO: currently no bounds-checking on immediate adds/etc
    #       -- immediate can be (a) 12-bit unsigned (b) flex operand
    #       -- just use (a) and a register otherwise
    #       (this seemed like a fix that could be done later)
    def operand_immediate(value)
      instrs = []
      src = Register.reg(Minic::LLVM::Register.alloc("i32"))
      #instrs << Instruction.mov(dest: src, srcs: [Register.reg(value.to_i)])
      instrs += mov_instr(src, value.to_i)
      [instrs, src]
    end

    def generate_branch(body)
      instrs = []
      if body[:no_cond]
        instrs << Instruction.b(cond: nil, target: body[:true_label])
      else
        instrs << Instruction.cmp(srcs: [Register.reg(body[:cond_reg]), Register.reg(1)])
        instrs << Instruction.b(cond: :eq, target: body[:true_label])
        instrs << Instruction.b(cond: nil, target: body[:false_label])
      end
      instrs
    end

    def generate_invocation(body, stack)
      instrs = caller_save((0..3), stack)
      body[:arg_regs].each_with_index do |src, index|
        if index < 4
          instrs += mov_instr(Register.phys_reg("r#{index}"), Register.reg(src))
        else
          sp_offset = (index - 4) * 4
          if src.immediate
            source = Register.phys_reg("r4")
            instrs += mov_instr(source, src)
          else
            source = src
          end
          instrs << Instruction.store(dest: Register.phys_reg("sp"), srcs: [Register.reg(source)], pre: {size: sp_offset, update: false})
        end
      end
      instrs << Instruction.bl(target: body[:name])
      if body[:target_reg] && @function_table[body[:name]][:return_type] != "void"
        instrs += mov_instr(body[:target_reg], Register.phys_reg("r0"))
      end
      instrs += caller_restore((0..3), stack)
      instrs
    end

    def generate_store(target, source, stack)
      if target.global
        instrs = []
        if source.immediate
          src_reg = Register.reg(Minic::LLVM::Register.alloc("i32*"))
          instrs += mov_instr(src_reg, source)
        else
          src_reg = Register.reg(source)
        end
        tmp_reg = Register.reg(Minic::LLVM::Register.alloc("i32*"))
        instrs += [
          Instruction.movw_label(dest: tmp_reg, name: "#:lower16:" + target.name),
          Instruction.movt_label(dest: tmp_reg, name: "#:upper16:" + target.name),
          Instruction.store(dest: tmp_reg, srcs: [src_reg])
        ]
        instrs
      elsif source.immediate
        tmp_reg = Register.reg(Minic::LLVM::Register.alloc("i32*"))
        mov_instr(tmp_reg, source.immediate.to_i) + generate_store(target, tmp_reg, stack)
      elsif stack.exists?(target.name)
        [stack.store(target.name, Register.reg(source))]
      else
        [Instruction.store(dest: Register.reg(target), srcs: [Register.reg(source)])]
      end
    end

    def generate_load(target, source, stack)
      if source.global
        tmp_reg = Register.reg(Minic::LLVM::Register.alloc("i32*"))
        [
          Instruction.movw_label(dest: tmp_reg, name: "#:lower16:" + source.name),
          Instruction.movt_label(dest: tmp_reg, name: "#:upper16:" + source.name),
          Instruction.load(dest: Register.reg(target), srcs: [tmp_reg])
        ]
      elsif source.immediate
        mov_instr(target, source.immediate.to_i)
      elsif stack.exists?(source.name)
        [stack.load(source.name, Register.reg(target))]
      else
        [Instruction.load(dest: Register.reg(target), srcs: [Register.reg(source)])]
      end
    end

    def generate_compare(body)
      target = body[:target_reg]
      left = body[:left_reg]
      right = body[:right_reg]
      cond_map = {
        "eq" => :eq,
        "ne" => :ne,
        "sgt" => :gt,
        "sge" => :ge,
        "slt" => :lt,
        "sle" => :le,
      }
      op = cond_map[body[:condition]]
      if left.immediate && right.immediate
        value = simplify_binary_expr(op, left.immediate.to_i, right.immediate.to_i)
        mov_instr(target, value)
      else
        instrs = []
        instrs << Instruction.mov(dest: Register.reg(target), srcs: [Register.reg(0)])
        if left.immediate
          imm_instrs, imm_reg = operand_immediate(left.immediate.to_i)
          instrs += imm_instrs
          tmp_reg = Minic::LLVM::Register.alloc("i32")
          instrs += mov_instr(tmp_reg, imm_reg)
          instrs << Instruction.cmp(srcs: [tmp_reg, Register.reg(right)])
        elsif right.immediate
          imm_instrs, imm_reg = operand_immediate(right.immediate.to_i)
          instrs += imm_instrs
          instrs << Instruction.cmp(srcs: [Register.reg(left), imm_reg])
        else
          instrs << Instruction.cmp(srcs: [Register.reg(left), Register.reg(right)])
        end
        instrs << Instruction.mov(cond: op, dest: Register.reg(target), srcs: [Register.reg(1)])
        instrs
      end
    end

    def generate_ret(b)
      if b[:void]
        []
      else
        mov_instr(Register.phys_reg("r0"), b[:source_reg])
      end
    end

    def generate_deref(b)
      [Instruction.add(dest: Register.reg(b[:target_reg]), srcs: [Register.reg(b[:source_reg]), Register.reg(4 * b[:index])])]
    end

    def generate_malloc(b, stack)
      instrs = mov_instr(Register.phys_reg("r0"), b[:size])
      instrs += caller_save((1..3), stack)
      instrs << Instruction.bl(target: "malloc")
      instrs += caller_restore((1..3), stack)
      instrs += mov_instr(b[:target_reg], Register.phys_reg("r0"))
      instrs
    end

    def generate_free(b, stack)
      instrs = mov_instr(Register.phys_reg("r0"), b[:source_reg])
      instrs += caller_save((1..3), stack)
      instrs << Instruction.bl(target: "free")
      instrs += caller_restore((1..3), stack)
      instrs
    end

    def generate_arith(op, b, stack)
      target = b[:target_reg]
      left = b[:left_reg]
      right = b[:right_reg]
      if left.immediate && right.immediate
        value = simplify_binary_expr(op, left.immediate.to_i, right.immediate.to_i)
        mov_instr(target, value)
      else
        case op
        when :add
          generate_add(target, left, right)
        when :sub
          generate_sub(target, left, right)
        when :mul
          generate_mul(target, left, right)
        when :sdiv
          generate_div(target, left, right, stack)
        end
      end
    end

    def generate_add(target, left, right)
      instrs = []
      if left.immediate
        imm_instrs, imm_reg = operand_immediate(left.immediate.to_i)
        instrs += imm_instrs
        instrs << Instruction.add(dest: Register.reg(target), srcs: [Register.reg(right), imm_reg])
      elsif right.immediate
        imm_instrs, imm_reg = operand_immediate(right.immediate.to_i)
        instrs += imm_instrs
        instrs << Instruction.add(dest: Register.reg(target), srcs: [Register.reg(left), imm_reg])
      else
        instrs << Instruction.add(dest: Register.reg(target), srcs: [Register.reg(left), Register.reg(right)])
      end
      instrs
    end

    def generate_mul(target, left, right)
      instrs = []
      tmp_reg = Minic::LLVM::Register.alloc("i32")
      if left.immediate
        imm_instrs, imm_reg = operand_immediate(left.immediate.to_i)
        instrs += imm_instrs
        instrs += mov_instr(tmp_reg, imm_reg)
        instrs << Instruction.mul(dest: Register.reg(target), srcs: [Register.reg(right), tmp_reg])
      elsif right.immediate
        imm_instrs, imm_reg = operand_immediate(right.immediate.to_i)
        instrs += imm_instrs
        instrs += mov_instr(tmp_reg, imm_reg)
        instrs << Instruction.mul(dest: Register.reg(target), srcs: [Register.reg(left), tmp_reg])
      else
        instrs << Instruction.mul(dest: Register.reg(target), srcs: [Register.reg(left), Register.reg(right)])
      end
      instrs
    end

    def generate_sub(target, left, right)
      instrs = []
      if left.immediate
        imm_instrs, imm_reg = operand_immediate(left.immediate.to_i)
        instrs += imm_instrs
        tmp_reg = Minic::LLVM::Register.alloc("i32")
        instrs += mov_instr(tmp_reg, imm_reg)
        instrs << Instruction.sub(dest: Register.reg(target), srcs: [tmp_reg, Register.reg(right)])
      elsif right.immediate
        imm_instrs, imm_reg = operand_immediate(right.immediate.to_i)
        instrs += imm_instrs
        instrs << Instruction.sub(dest: Register.reg(target), srcs: [Register.reg(left), imm_reg])
      else
        instrs << Instruction.sub(dest: Register.reg(target), srcs: [Register.reg(left), Register.reg(right)])
      end
      instrs
    end

    def generate_div(target, left, right, stack)
      instrs = []
      r0 = Register.phys_reg("r0")
      r1 = Register.phys_reg("r1")
      instrs = mov_instr(r0, left)
      instrs += mov_instr(r1, right)
      instrs += caller_save((2..3), stack)
      instrs << Instruction.bl(target: "__aeabi_idiv")
      instrs += caller_restore((2..3), stack)
      instrs += mov_instr(target, r0)
      instrs
    end

    def generate_logic(op, b)
      target = b[:target_reg]
      left = b[:left_reg]
      right = b[:right_reg]
      if left.immediate && right.immediate
        value = simplify_binary_expr(op, left.immediate.to_i, right.immediate.to_i)
        mov_instr(target, value)
      else
        instrs = []
        if left.immediate
          imm_instrs, imm_reg = operand_immediate(left.immediate.to_i)
          instrs += imm_instrs
          arg1, arg2 = [Register.reg(right), imm_reg]
        elsif right.immediate
          imm_instrs, imm_reg = operand_immediate(right.immediate.to_i)
          instrs += imm_instrs
          arg1, arg2 = [Register.reg(left), imm_reg]
        else
          arg1, arg2 = [Register.reg(left), Register.reg(right)]
        end
        case op
        when :and
          instrs << Instruction.and(dest: Register.reg(target), srcs: [arg1, arg2])
        when :xor
          instrs << Instruction.eor(dest: Register.reg(target), srcs: [arg1, arg2])
        when :or
          instrs << Instruction.orr(dest: Register.reg(target), srcs: [arg1, arg2])
        end
        instrs
      end
    end

    def simplify_binary_expr(op, left, right)
      case op
      when :add
        left + right
      when :sub
        left - right
      when :mul
        left * right
      when :sdiv
        if left == 0 && right == 0
          0
        elsif right == 0
          raise "Can't divide by 0"
        else
          left / right
        end
      when :and
        left & right
      when :xor
        left ^ right
      when :or
        left | right
      when :eq
        left == right ? 1 : 0
      when :ne
        left != right ? 1 : 0
      when :lt
        left < right ? 1 : 0
      when :le
        left <= right ? 1 : 0
      when :gt
        left > right ? 1 : 0
      when :ge
        left >= right ? 1 : 0
      else
        raise "Can't simplify #{op}"
      end
    end

    def generate_scanf(b, stack)
      instrs = []
      r0 = Register.phys_reg("r0")
      r1 = Register.phys_reg("r1")
      instrs += caller_save((0..3), stack)
      target = Register.reg(b[:target_reg])
      instrs += [
        Instruction.movw_label(dest: r1, name: "#:lower16:.read_scratch"),
        Instruction.movt_label(dest: r1, name: "#:upper16:.read_scratch"),
        Instruction.movw_label(dest: r0, name: "#:lower16:.READ_FMT"),
        Instruction.movt_label(dest: r0, name: "#:upper16:.READ_FMT"),
        Instruction.bl(target: "scanf")
      ]
      if b[:target_reg].type == "i32*"
        tmp_reg = Minic::LLVM::Register.alloc("i32*")
        instrs += [
          Instruction.movw_label(dest: tmp_reg, name: "#:lower16:.read_scratch"),
          Instruction.movt_label(dest: tmp_reg, name: "#:upper16:.read_scratch"),
          Instruction.load(dest: tmp_reg, srcs: [tmp_reg], pre: nil, post: nil),
        ]
        instrs += generate_store(b[:target_reg], tmp_reg, stack)
      else
        instrs += [
          Instruction.movw_label(dest: target, name: "#:lower16:.read_scratch"),
          Instruction.movt_label(dest: target, name: "#:upper16:.read_scratch"),
          Instruction.load(dest: target, srcs: [target], pre: nil, post: nil)
        ]
        instrs += generate_store(b[:target_reg], target, stack)
      end
      instrs += caller_restore((0..3), stack)
      instrs
    end


    def generate_printf(b, stack)
      r0 = Register.phys_reg("r0")
      r1 = Register.phys_reg("r1")
      fmt = b[:endl] ? ".PRINTLN_FMT" : ".PRINT_FMT"
      instrs = caller_save((0..3), stack)
      instrs += mov_instr(r1, b[:source_reg])
      instrs << Instruction.movw_label(dest: r0, name: "#:lower16:#{fmt}")
      instrs << Instruction.movt_label(dest: r0, name: "#:upper16:#{fmt}")
      instrs << Instruction.bl(target: "printf")
      instrs += caller_restore((0..3), stack)
      instrs
    end

    def collect_phi(phi)
      @phis << phi unless phi.body[:trivial]
      []
    end

    def generate_phi(phi)
      preds = phi.body[:block].predecessors
      target_reg = Register.reg(phi.body[:target_reg])
      phi.body[:source_regs].each_with_index do |reg, index|
        block = preds.find {|pred| pred.label == phi.body[:source_labels][index]}
        instr_index = block.arm.index {|instr| instr.opcode == :b || (instr.opcode == :mov && instr.body[:phi])}
        source_reg = Register.reg(reg)
        if instr_index
          block.arm.insert(instr_index, Instruction.mov(phi: true, dest: target_reg, srcs: [source_reg]))
        else
          block.arm.push(Instruction.mov(phi: true, dest: target_reg, srcs: [source_reg]))
        end
      end
      []
    end

    def is_immediate(src)
      src.is_a?(Integer) || src.is_a?(String) || src.is_a?(TrueClass) || src.is_a?(FalseClass) || src.immediate
    end

    def convert_immediate(imm)
      if imm.is_a?(Integer)
        imm
      elsif imm.is_a?(String)
        imm.to_i
      elsif imm.is_a?(TrueClass) || imm.is_a?(FalseClass)
        imm ? 1 : 0
      elsif imm.is_a? Minic::ARM::Register
        convert_immediate imm.value
      elsif imm.is_a? Minic::LLVM::Register
        convert_immediate imm.immediate
      else
        raise "Cannot convert immediate value for #{imm.class}"
      end
    end
  end
end
