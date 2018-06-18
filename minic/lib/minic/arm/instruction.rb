module Minic::ARM
  class Instruction
    include Minic::Errors
    attr_accessor :opcode, :body

    class << self
      def directive(name:, args:)
        Instruction.new(:directive, {name: name, args: args})
      end

      def label(name:)
        Instruction.new(:label, {name: name})
      end

      def placeholder(label:)
        Instruction.new(:placeholder, {label: label})
      end

      def bx
        Instruction.new(:bx, {name: name})
      end

      def store(dest:, srcs:, pre: nil, post: nil)
        srcs.size == 1 or raise "str requires exactly 1 source, got #{srcs.size}"
        Instruction.new(:str, {dest: Register.reg(dest), srcs: Register.reg(srcs), pre: pre, post: post})
      end

      def load(dest:, srcs:, pre: nil, post: nil)
        srcs.size == 1 or raise "ldr requires exactly 1 source, got #{srcs.size}"
        Instruction.new(:ldr, {dest: Register.reg(dest), srcs: Register.reg(srcs), pre: pre, post: post})
      end

      def push(srcs:)
        srcs.size > 0 or raise "should not push 0 values to the stack"
        Instruction.new(:push, {srcs: Register.reg(srcs)})
      end

      def pop(dests:)
        dests.size > 0 or raise "should not pop 0 values off of the stack"
        Instruction.new(:pop, {dests: Register.reg(dests)})
      end

      def mov(cond: nil, dest:, srcs:, phi: false)
        srcs.size == 1 or raise "mov requires exactly 1 source, got #{srcs.size}"
        [:eq, :ne, :gt, :ge, :lt, :le, nil].include?(cond) or raise "mov cannot accept condition #{cond}"
        Instruction.new(:mov, {cond: cond, dest: Register.reg(dest), srcs: Register.reg(srcs), phi: phi})
      end

      def movw(cond: nil, dest:, srcs:)
        srcs.size == 1 or raise "movw requires exactly 1 source, got #{srcs.size}"
        [:eq, :ne, :gt, :ge, :lt, :le, nil].include?(cond) or raise "mov cannot accept condition #{cond}"
        Instruction.new(:movw, {cond: cond, dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def movt(cond: nil, dest:, srcs:)
        srcs.size == 1 or raise "movt requires exactly 1 source, got #{srcs.size}"
        [:eq, :ne, :gt, :ge, :lt, :le, nil].include?(cond) or raise "mov cannot accept condition #{cond}"
        Instruction.new(:movt, {cond: cond, dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def movw_label(dest:, name:)
        Instruction.new(:movw_label, {dest: Register.reg(dest), name: name})
      end

      def movt_label(dest:, name:)
        Instruction.new(:movt_label, {dest: Register.reg(dest), name: name})
      end

      def add(dest:, srcs:)
        srcs.size == 2 or raise "add requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:add, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def sub(dest:, srcs:)
        srcs.size == 2 or raise "sub requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:sub, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def mul(dest:, srcs:)
        srcs.size == 2 or raise "mul requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:mul, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def and(dest:, srcs:)
        srcs.size == 2 or raise "and requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:and, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def orr(dest:, srcs:)
        srcs.size == 2 or raise "or requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:orr, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def eor(dest:, srcs:)
        srcs.size == 2 or raise "eor requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:eor, {dest: Register.reg(dest), srcs: Register.reg(srcs)})
      end

      def cmp(srcs:)
        srcs.size == 2 or raise "cmp requires exactly 2 sources, got #{srcs.size}"
        Instruction.new(:cmp, {srcs: Register.reg(srcs)})
      end

      def b(cond: nil, target:)
        [:eq, :ne, :gt, :ge, :lt, :le, nil].include?(cond) or raise "branch cannot accept condition #{cond}"
        Instruction.new(:b, {cond: cond, target: target})
      end

      def bl(target:)
        Instruction.new(:bl, {target: target})
      end

      def nyi
        Instruction.new(:nyi, {name: name})
      end

      def redundant(instr)
        # add more redundancy cases here
        case instr.opcode
        when :mov
          if instr.body[:dest] == instr.body[:srcs][0]
            true
          else
            false
          end
        else
          false
        end
      end
    end

    def initialize(opcode, body)
      @opcode = opcode
      @body = body
    end

    def to_arm
      b = @body
      case @opcode
      when :global
        "#{b[:name]}: .word 0"
      when :ref
        "#{b[:name]}: .word #{b[:to]}"
      when :directive
        ".#{b[:name]} #{b[:args].join(", ")}"
      when :label
        "#{b[:name]}:"
      when :bx
        "    bx lr"
      when :mov
        "    mov#{b[:cond]} #{b[:dest].to_s}, #{b[:srcs][0].to_s}"
      when :movw
        "    movw#{b[:cond]} #{b[:dest].to_s}, #{b[:srcs][0].to_s}"
      when :movt
        "    movt#{b[:cond]} #{b[:dest].to_s}, #{b[:srcs][0].to_s}"
      when :movt_label
        "    movt #{b[:dest].to_s}, #{b[:name]}"
      when :movw_label
        "    movw #{b[:dest].to_s}, #{b[:name]}"
      when :add, :sub, :mul
        "    #{@opcode.to_s} #{b[:dest].to_s}, #{b[:srcs][0].to_s}, #{b[:srcs][1].to_s}"
      when :and, :orr, :eor
        "    #{@opcode.to_s} #{b[:dest].to_s}, #{b[:srcs][0].to_s}, #{b[:srcs][1].to_s}"
      when :str
        str_to_s b
      when :ldr
        ldr_to_s b
      when :push
        "    push {#{b[:srcs].map {|s| s.to_s}.join(", ")}}"
      when :pop
        "    pop  {#{b[:dests].map {|d| d.to_s}.join(", ")}}"
      when :cmp
        "    cmp #{b[:srcs][0].to_s}, #{b[:srcs][1].to_s}"
      when :b
        branch_to_s b
      when :bl
        "    bl #{b[:target]}"
      when :nyi
        "    nyi"
      else
      end
    end

    def str_to_s(body)
      if body[:pre]
        dest = "[#{body[:dest].to_s}, ##{body[:pre][:size].to_s}]#{body[:pre][:update] ? "!" : ""}"
      elsif body[:post]
        dest = "[#{body[:dest].to_s}], ##{body[:pre][:size].to_s}"
      else
        dest = "[#{body[:dest].to_s}]"
      end
      "    str #{body[:srcs][0].to_s}, #{dest}"
    end

    def ldr_to_s(body)
      if body[:pre]
        src = "[#{body[:srcs][0].to_s}, ##{body[:pre][:size].to_s}]#{body[:pre][:update] ? "!" : ""}"
      elsif body[:post]
        src = "[#{body[:srcs][0].to_s}], ##{body[:pre][:size].to_s}"
      else
        src = "[#{body[:srcs][0].to_s}]"
      end
      "    ldr #{body[:dest].to_s}, #{src}"
    end

    def branch_to_s(body)
      case body[:cond]
      when nil
        "    b #{body[:target]}"
      when :eq
        "    beq #{body[:target]}"
      else
        "    nyi"
      end
    end
  end
end
