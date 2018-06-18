module Minic
  class Block
    include Errors
    attr_accessor :label, :func_id, :predecessors, :successors, :contents, :llvm, :arm, :gen_set, :kill_set, :live_out_set, :killed, :dummy, :marked
    @@counter = 0

    def initialize(func_id, contents=nil, dummy=false)
      @label = "B#{@@counter}"
      @@counter += 1
      @func_id = func_id
      @dummy = dummy
      @predecessors = []
      @successors = []
      @contents = (contents or [])
      @llvm = []
      @arm = []
      @pre_func = []
      @gen_set = Set[]
      @kill_set = Set[]
      @live_out_set = Set[]
      @killed = Set[]
      @marked = 0
    end

    def self.reset_counter
      @@counter = 0
    end

    def push_predecessor(block)
      @predecessors.push(block)
    end

    def push_successor(label, block)
      @successors.push({label: label, block: block})
    end

    def to_llvm(indent)
      "#{@label}:\n" + @llvm.collect do |instr|
        llvm = instr.to_llvm
        (" "* 4 *indent) << llvm if llvm
      end.compact.join("\n")
    end

    def to_arm
      @arm.collect {|i| i.to_arm}.join("\n")
    end

    def to_dot(indent)
      accum = ""
      if @successors.empty? || @predecessors.empty?
        accum << "#{" "*indent}#{@label} [style=\"bold\"]\n"
      elsif @contents.empty?
        accum << "#{" "*indent}#{@label} [label=\"#{@label}(NOP)\"]\n"
      else
        accum << "#{" "*indent}#{@label}\n"
      end
      @successors.each_with_index do |edge|
        accum << "#{" "*indent}#{@label} -> #{edge[:block].label}"
        if [:true, :false].include? edge[:label]
          accum << " [label=\"#{edge[:label].to_s}\"]"
        end
        accum << ";\n"
      end
      accum
    end

    def translate_to_llvm(translator)
      @contents.each do |statement|
        @llvm += translator.generate(@func_id, self, statement)
      end
      if @successors.size == 1
        @llvm << translator.next_block(self)
      end
    end

    def translate_to_arm(translator, stack)
      @arm << ARM::Instruction.label(name: @label)
      @llvm.each do |llvm|
        @arm += translator.generate(@func_id, llvm, stack)
      end
    end
  end
end

