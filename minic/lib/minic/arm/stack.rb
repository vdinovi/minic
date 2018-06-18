module Minic::ARM
  class Stack
    include Minic::ARM
    include Minic::Errors
    attr_accessor :stack, :spills

    def initialize
      @stack = []
      @spills = []
    end

    def offset(key)
      index = @stack.index(key) or raise "#{key} not found on the stack"
      index * -4
    end

    def exists?(key)
      @stack.include? key
    end

    def load(key, dst)
      Instruction.load(dest: dst, srcs: [Register.phys_reg("fp")], pre: {size: offset(key), update: false})
    end

    def store(key, src)
      Instruction.store(dest: Register.phys_reg("fp"), srcs: [src], pre: {size: offset(key), update: false})
    end

    def push(srcs)
      srcs.each { |src| @stack.push(src.value) }
      Instruction.push(srcs: srcs)
    end

    def pop(dsts)
      dsts.each { @stack.pop }
      Instruction.pop(dests: dsts)
    end

    def alloc(srcs)
      decrement = srcs.size * 4
      srcs.each { |src| @stack.push(src.value) }
      Instruction.sub(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(decrement)])
    end

    def alloc_space(size)
      size.times { @stack.push(nil) }
      Instruction.sub(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(size * 4)])
    end

    def dealloc
      size = @stack.size * 4
      Instruction.add(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(size)])
    end

    def dealloc_to(name)
      index = @stack.index(name) or raise "#{name} not found on the stack"
      size = 4 * (@stack.size - 1 - index)
      Instruction.add(dest: Register.phys_reg("sp"), srcs: [Register.phys_reg("sp"), Register.reg(size)])
    end

    def add_spill(key)
      @spills.push(key)
    end

    def store_spill(key, src)
      index = @spills.index(key) or raise "#{key} not found in spills"
      offset = -(@stack.size + index + 2) * 4
      Instruction.store(dest: Register.phys_reg("fp"), srcs: [src], pre: {size: offset, update: false})
    end

    def load_spill(key, dst)
      index = @spills.index(key) or raise "#{key} not found in spills"
      offset = -(@stack.size + index + 2) * 4
      Instruction.load(dest: dst, srcs: [Register.phys_reg("fp")], pre: {size: offset, update: false})
    end

    def to_s
      if @stack.empty?
        "(empty)"
      else
        "| " + @stack.join(" | ") + " |"
      end
    end
  end
end
