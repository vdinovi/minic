require 'bundler/setup'
require 'minic/errors'
require 'minic/llvm'
require 'minic/arm'
require 'minic/block'
require 'objspace'

module Minic
  class CFG
    include Errors
    attr_accessor :graphs

    Graph = Struct.new(:entry, :exit, :blocks, :pre, :post, :stack)

    class << self
      def generate_from_json_file(filename)
        File.open(filename, 'r') do |file|
          input = JSON.parse(file.read, symbolize_names: true)
          fix_keys(input)
          self.new(input)
        end
      end

      def generate(input)
        self.new(input)
      end
    end

    def initialize(input)
      @ast = input[:ast] or raise CFGError.new("invalid input - missing :ast", nil)
      @struct_table = input[:struct_table] or raise CFGError.new("invalid input - missing :struct_table", nil)
      @global_table = input[:global_table] or raise CFGError.new("invalid input - missing :global_table", nil)
      @function_table = input[:function_table] or raise CFGError.new("invalid input - missing :function_table", nil)

      @graphs = {}
      @func_decl_instrs = {}

      @llvm = []
      @llvm_translated = false

      @arm = {data: [], text: []}
      @arm_translator = ARM::Translator.new(@struct_table, @global_table, @function_table)
      @arm_translated = false

      generate_graphs
    end

    def translate_to_llvm(stack = False)
      if stack
        llvm_translator = LLVM::StackTranslator.new(@struct_table, @global_table, @function_table)
      else
        llvm_translator = LLVM::SSATranslator.new(@struct_table, @global_table, @function_table)
      end

      @llvm <<  LLVM::Instruction.misc(data: "target triple=\"i686\"")
      @struct_table.each do |name, struct|
        @llvm += llvm_translator.struct_declaration(name, struct)
      end
      @global_table.each do |name, global|
        @llvm += llvm_translator.global_declaration(name, global)
      end
      @function_table.each do |name, func|
        @func_decl_instrs[name] = llvm_translator.func_declaration(name, func)
      end
      @graphs.each do |name, graph|
        func = @function_table[name]
        graph.entry.llvm += llvm_translator.function_begin(name, func, graph.entry)
        graph.blocks.each do |block|
          block.translate_to_llvm(llvm_translator)
          llvm_translator.attempt_seal(block)
        end
        graph.exit.llvm += llvm_translator.function_end(name, func, graph.exit)
        llvm_translator.seal_blocks(graph)
        llvm_translator.remove_trivial_phis(graph)
        llvm_translator.reorder_phis(graph)
      end
      @llvm_translated = true
    end

    def translate_to_arm
      @llvm_translated or raise CFGError.new("Must translate the CFG to LLVM fefore translating to ARM", nil)
      @arm[:text] += @global_table.keys.map {|name| ARM::Instruction.directive(name: "comm", args: [name, "4", "4"])}
      @arm[:text] << ARM::Instruction.directive(name: "arch", args: ["armv7-a"])
      @graphs.each do |name, graph|
        graph.stack = ARM::Stack.new
        @arm_translator.setup_arm_function(name, graph)
        graph.blocks.each do |block|
          block.translate_to_arm(@arm_translator, graph.stack)
        end
        @arm_translator.close_arm_function(name, graph)
      end
      @arm_translated = true
    end

    def interference_graph
      ARM::InterferenceGraph.new(@graphs)
    end

    def reg_alloc(if_graph)
      alloc_map = if_graph.reg_alloc(@arm_translator, @graphs)
      @graphs.values.each do |graph|
        graph.blocks.each do |block|
          block.arm.each_with_index do |arm, index|
            if ARM::Instruction.redundant(arm)
              block.arm[index] = nil
              next
            end
            arm.body[:srcs].map! {|src| !src.physical && !src.immediate ? alloc_map[src] : src } if arm.body[:srcs]
            if arm.body[:dest] && !arm.body[:dest].physical && !arm.body[:dest].immediate
              arm.body[:dest] = alloc_map[arm.body[:dest]]
            end
            block.arm[index] = nil if ARM::Instruction.redundant(arm)
            block.killed << arm.body[:dest] if arm.body[:dest]
            block.killed += arm.body[:dests] if arm.body[:dests]
          end
          block.arm.compact!
        end
      end
      # Fill in missing instructions
      @graphs.values.each do |graph|
        @arm_translator.callee_save(graph)
        @arm_translator.arg_space(graph)
        @arm_translator.spill_space(graph)
      end
    end

    def to_dot
      accum = "digraph G {\n"
      @graphs.each do |name, graph|
        accum << "    subgraph cluster_#{name} {\n"
        accum << "        label = \"#{name}\";\n"
        graph.blocks.each do |block|
          accum << block.to_dot(8)
        end
        accum << "    }\n"
      end
      accum << "}"
      accum
    end

    def to_llvm
      @llvm_translated or raise CFGError.new("Must translate the CFG to LLVM before exporting as LLVM", nil)
      accum = ""
      @llvm.each do |instr|
        accum << instr.to_llvm << "\n"
      end
      accum << "\n\n"
      @graphs.each do |name, graph|
        func = @function_table[name]
        accum << @func_decl_instrs[name].to_llvm << "\n"
        accum << "{\n"
        graph.blocks.each do |block|
          accum << "#{block.to_llvm(1)}\n"
        end
        accum << "}\n\n"
      end
      accum << "\n\n"
      common_llvm.each do |line|
        accum << line << "\n"
      end
      accum
    end

    def to_arm
      @arm_translated or raise CFGError.new("Must translate the CFG to ARM before exporting as ARM", nil)
      accum = ""
      @arm[:text].each { |instr| accum << instr.to_arm << "\n" }
      accum << "\n"
      @graphs.each do |_, graph|
        graph.pre.each { |instr| accum << instr.to_arm << "\n" }
        graph.blocks.each { |block| accum << block.to_arm << "\n" }
        graph.post.each { |instr| accum << instr.to_arm << "\n" }
        accum << "\n"
      end
      accum << "\n\n"
      common_arm.each do |line|
        accum << line << "\n"
      end
      accum
    end

    private

    def push_block(func_id, block)
      @graphs[func_id] or raise CFGError.new("trying to push block to uninitialized graph '#{func_id}'")
      @graphs[func_id].blocks.push(block)
    end

    def generate_graphs
      @ast[:functions].each do |func|
        func_id = func[:id]
        head = Block.new(func_id)
        tail = Block.new(func_id)
        @graphs[func_id] = Graph.new(head, tail, [head])

        last = generate_block(func_id, head, func[:body])
        tail.push_predecessor(last)
        last.push_successor(:next, tail)
        push_block(func_id, tail)
        @graphs[func_id].blocks.select {|block| block.dummy}.each do |block|
          block.successors.each {|succ| succ[:block].predecessors.delete(block) }
          @graphs[func_id].blocks.delete(block)
        end
      end
    end

    def generate_block(func_id, current, statements)
      statements.each do |stmt|
        current = generate_statement(func_id, current, stmt)
      end
      current
    end

    def generate_statement(func_id, current, statement)
      case statement[:stmt]
      when "block"
        generate_block(func_id, current, statement[:list])
      when "if"
        generate_if(func_id, current, statement)
      when "while"
        generate_while(func_id, current, statement)
      when "return"
        generate_return(func_id, current, statement)
      when"invocation", "print", "assign", "delete"
        current.contents << statement
        current
      else
        raise CFGError.new("invalid statement", statement)
      end
    end

    def generate_return(func_id, current, statement)
      current.contents << statement
      current.push_successor(:next, @graphs[func_id].exit)
      @graphs[func_id].exit.push_predecessor(current)
      dummy_block = Block.new(func_id, nil, true)
      dummy_block.push_predecessor(current)
      push_block(func_id, dummy_block)
      dummy_block
    end

    def generate_if(func_id, current, statement)
      current.contents << { stmt: "branch", guard: statement[:guard] }

      # Then
      then_block = Block.new(func_id)
      then_block.push_predecessor(current)
      current.push_successor(:true, then_block)
      push_block(func_id, then_block)

      last = generate_block(func_id, then_block, statement[:then][:list])
      join_block = Block.new(func_id)
      join_block.push_predecessor(last)
      last.push_successor(:next, join_block)

      # Else
      if statement[:else]
        else_block = Block.new(func_id)
        else_block.push_predecessor(current)
        current.push_successor(:false, else_block)
        push_block(func_id, else_block)

        last = generate_block(func_id, else_block, statement[:else][:list])
        last.push_successor(:next, join_block)
        join_block.push_predecessor(last)
      else
        join_block.push_predecessor(current)
        current.push_successor(:false, join_block)
      end

      join_block.dummy = join_block.predecessors.all? {|pred| pred.dummy}
      push_block(func_id, join_block)
      join_block
    end

    def generate_while(func_id, current, statement)
      current.contents << { stmt: "branch", guard: statement[:guard] }
      body_block = Block.new(func_id)
      break_block = Block.new(func_id)
      last = generate_block(func_id, body_block, statement[:body][:list])
      last.contents << { stmt: "branch", guard: statement[:guard] }
      #if last == body_block
      #  # This helps break some wierd cycles
      #  last = Block.new(func_id)
      #  body_block.push_successor(:next, last)
      #  last.push_predecessor(body_block)
      #  push_block(func_id, last)
      #end

      # current <-> body / break
      current.push_successor(:true, body_block)
      body_block.push_predecessor(current)
      current.push_successor(:false, break_block)
      break_block.push_predecessor(current)

      # last <-> body / break
      last.push_successor(:true, body_block)
      body_block.push_predecessor(last)
      last.push_successor(:false, break_block)
      break_block.push_predecessor(last)

      push_block(func_id, body_block)
      push_block(func_id, break_block)
      break_block
    end

    def common_llvm
      [
        "declare i8* @malloc(i32)",
        "declare void @free(i8*)",
        "declare i32 @printf(i8*, ...)",
        "declare i32 @scanf(i8*, ...)",
        "@.println = private unnamed_addr constant [5 x i8] c\"%ld\\0A\\00\", align 1",
        "@.print = private unnamed_addr constant [5 x i8] c\"%ld \\00\", align 1",
        "@.read = private unnamed_addr constant [4 x i8] c\"%ld\\00\", align 1",
        "@.read_scratch = common global i32 0, align 8"
      ]
    end

    def common_arm
      [
	      ".section	.rodata",
        ".align	2",
        ".PRINTLN_FMT:",
        ".asciz	\"%ld\\n\"",
        ".align	2",
        ".PRINT_FMT:",
        ".asciz	\"%ld \"",
        ".align	2",
        ".READ_FMT:",
        ".asciz	\"%ld\"",
        ".comm	.read_scratch,4,4",
        ".global	__aeabi_idiv"
      ]
    end

    def fix_keys(input)
      # reconvert identifier keys to strings (product of JSON serialization -- doesn't matter if (symbolize_names: false) is set)
      input[:struct_table].each { |_, s| s[:fields].keys.each { |k| s[:fields][k.to_s] = s[:fields].delete k } }
      input[:struct_table].keys.each { |k| input[:struct_table][k.to_s] = input[:struct_table].delete k }
      input[:struct_table].rehash
      input[:function_table].each { |_, s| s[:locals].keys.each { |k| s[:locals][k.to_s] = s[:locals].delete k } }
      input[:function_table].each { |_, s| s[:params].keys.each { |k| s[:params][k.to_s] = s[:params].delete k } }
      input[:function_table].keys.each { |k| input[:function_table][k.to_s] = input[:function_table].delete k }
      input[:function_table].rehash
      input[:global_table].keys.each { |k| input[:global_table][k.to_s] = input[:global_table].delete k }
      input[:global_table].rehash
    end
  end
end
