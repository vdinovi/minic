module Minic::LLVM
  class Instruction
    include Minic::Errors
    attr_accessor :opcode, :body

    class << self
      def struct_decl(name:, fields:)
        Instruction.new(:struct_decl, {name: name, fields: fields})
      end

      def global_decl(target:)
        Instruction.new(:global_decl, {target_reg: target})
      end

      def func_decl(name:, params:, return_type:)
        Instruction.new(:func_decl, {name: name, params: params, return_type: return_type})
      end

      def alloca(type:, target:)
        Instruction.new(:alloca, {type: type, target_reg: target })
      end

      def load(source:, target:)
        Instruction.new(:load, {source_reg: source, target_reg: target})
      end

      def store(source:, target:)
        Instruction.new(:store, {source_reg: source, target_reg: target})
      end

      def ret(source:, void: false)
        Instruction.new(:ret, {source_reg: source, void: void})
      end

      def read(target:)
        Instruction.new(:read, {target_reg: target})
      end

      def malloc(size:, target:)
        Instruction.new(:malloc, {size: size, target_reg: target})
      end

      def free(source:)
        Instruction.new(:free, {source_reg: source})
      end

      def print(source:, endl:)
        Instruction.new(:print, {source_reg: source, endl: endl})
      end

      def bitcast(source:, target:)
        Instruction.new(:bitcast, {source_reg: source, target_reg: target})
      end

      def getelemptr(source:, index:, target:)
        Instruction.new(:getelementptr, {source_reg: source, index: index, target_reg: target})
      end

      def arith(op:, left:, right:, target:)
        ops = {
          "+" => :add,
          "-" => :sub,
          "*" => :mul,
          "/" => :sdiv
        }
        Instruction.new(ops[op], {left_reg: left, right_reg: right, target_reg: target})
      end

      def xor(left:, right:, target:)
        Instruction.new(:xor, {left_reg: left, right_reg: right, target_reg: target})
      end

      def and(left:, right:, target:)
        Instruction.new(:and, {left_reg: left, right_reg: right, target_reg: target})
      end

      def or(left:, right:, target:)
        Instruction.new(:or, {left_reg: left, right_reg: right, target_reg: target})
      end

      def icmp(cond:, left:, right:, target:)
        conds = {
          "==" => "eq",
          "!=" => "ne",
          ">"  => "sgt",
          ">=" => "sge",
          "<"  => "slt",
          "<=" => "sle",
        }
        Instruction.new(:icmp, {condition: conds[cond], left_reg: left, right_reg: right, target_reg: target})
      end

      def zext(source:, target:)
        Instruction.new(:zext, {source_reg: source, target_reg: target})
      end

      def truncate(source:, target:)
        Instruction.new(:trunc, {source_reg: source, target_reg: target})
      end

      def invocation(name:, args:, target:, void: false, statement: false, return_type: nil)
        Instruction.new(:invocation, {name: name, arg_regs: args, target_reg: target, void: void, statement: statement, return_type: return_type})
      end

      def branch(cond:, true_label:, false_label:, no_cond: false)
        Instruction.new(:branch, {cond_reg: cond, true_label: true_label, false_label: false_label, no_cond: no_cond})
      end

      def misc(data:)
        Instruction.new(:misc, {data: data})
      end

      def phi(sources:, labels:, target:, trivial: false)
        Instruction.new(:phi, {source_regs: sources, source_labels: labels, target_reg: target, trivial: trivial})
      end

      def nyi
        Instruction.new(:nyi, nil)
      end
    end

    def initialize(opcode, body)
      @opcode = opcode
      @body = body
    end

    def to_llvm
      b = @body
      case @opcode
      when :struct_decl
        "%struct.#{b[:name]} = type {#{b[:fields].join(', ')}}"
      when :global_decl
        "@#{b[:target_reg].name} = common global #{b[:target_reg].type} #{b[:target_reg].immediate}, align 8"
      when :func_decl
        params = b[:params].map {|r| "#{r.type} #{r.to_s}" }.join(', ')
        "define #{b[:return_type]} @#{b[:name]}(#{params})"
      when :alloca
        "#{b[:target_reg].to_s} = alloca #{b[:type]}"
      when :load
        "#{b[:target_reg].to_s} = load #{b[:source_reg].type} #{b[:source_reg].to_s}"
      when :store
        "store #{b[:source_reg].type} #{b[:source_reg].to_s}, #{b[:target_reg].type} #{b[:target_reg].to_s}"
      when :ret
        b[:void] ? "ret void" : "ret #{b[:source_reg].type} #{b[:source_reg].to_s}"
      when :read
        "call i32 (i8*, ...)* @scanf(i8* getelementptr inbounds ([4 x i8]* @.read, i32 0, i32 0), #{b[:target_reg].type} #{b[:target_reg].to_s})"
      when :malloc
        "#{b[:target_reg].to_s} = call i8* @malloc(i32 #{b[:size]})"
      when :getelementptr
        "#{b[:target_reg].to_s} = getelementptr #{b[:source_reg].type} #{b[:source_reg].to_s}, i1 0, i32 #{b[:index]}"
      when :add, :sub, :mul, :sdiv, :xor, :and, :or
        "#{b[:target_reg].to_s} = #{@opcode} #{b[:left_reg].type} #{b[:left_reg].to_s}, #{b[:right_reg].to_s}"
      when :icmp
        "#{b[:target_reg].to_s} = icmp #{b[:condition]} #{b[:left_reg].type} #{b[:left_reg].to_s}, #{b[:right_reg].to_s}"
      when :zext, :trunc, :bitcast
        "#{b[:target_reg].to_s} = #{@opcode} #{b[:source_reg].type} #{b[:source_reg].to_s} to #{b[:target_reg].type}"
      when :invocation
        args = b[:arg_regs].map {|a| "#{a.type} #{a.to_s}" }.join(', ')
        if b[:statement]
          "call #{b[:return_type]} @#{b[:name]}(#{args})"
        else
          prefix = b[:void] ? "call void" : "#{b[:target_reg].to_s} = call #{b[:target_reg].type}"
          "#{prefix} @#{b[:name]}(#{args})"
        end
      when :print
        value = b[:source_reg].immediate ? "i32 #{b[:source_reg].immediate}" : "#{b[:source_reg].type} #{b[:source_reg].to_s}"
        "call i32 (i8*, ...)* @printf(i8* getelementptr inbounds ([5 x i8]* #{b[:endl] ? "@.println" : "@.print"}, i32 0, i32 0), #{value})"
      when :free
        "call void @free(#{b[:source_reg].type} #{b[:source_reg].to_s})"
      when :branch
        if b[:no_cond]
          "br label %#{b[:true_label]}"
        else
          "br #{b[:cond_reg].type} #{b[:cond_reg].to_s}, label %#{b[:true_label]}, label %#{b[:false_label]}"
        end
      when :misc
        "#{b[:data]}"
      when :phi
        if b[:trivial]
          nil
        else
          b[:source_regs].any? or raise "Phi with no sources"
          #type = b[:source_regs].find{|reg| reg.type }.type
          #b[:target_reg].type = type
          #b[:source_regs].each {|reg| reg.type = type}
          operands = b[:source_regs].each_with_index.map {|reg, index| "[#{reg}, %#{b[:source_labels][index]}]"}.join(', ')
          b[:target_reg].type = b[:source_regs].first.type unless b[:target_reg].type
          "#{b[:target_reg].to_s} = phi #{b[:target_reg].type} #{operands}"
        end
      when :nyi
        "#{@opcode}"
      else
        raise "instruction with unknown opcode '#{@opcode}'"
      end
    end
  end
end
