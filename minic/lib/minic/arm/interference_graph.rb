module Minic::ARM
  class InterferenceGraph
    attr_accessor :graph, :colors

    # r9 and r10 are spill registers
    #REGISTERS = ["r0", "r1", "r2", "r3", "r4", "fp", "lr", "sp", "pc"].freeze
    REGISTERS = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "fp", "lr", "sp", "pc"].freeze
    SPECIAL = ["fp", "lr", "sp", "pc"].freeze
    COLORS = {
      "r0":  "#FF0000",
      "r1":  "#008000",
      "r2":  "#87CEFA",
      "r3":  "#FA8072",
      "r4":  "#FFFF00",
      "r5":  "#800080",
      "r6":  "#FFC0CB",
      "r7":  "#D2B48C",
      "r8":  "#C0C0C0",
      "r9":  "#FFA500",
      "r10": "#00FFFF",
      "fp": "#808000",
      "lr": "#000000",
      "sp": "#CD5C5C",
      "pc": "#000000"
    }.freeze

    def initialize(cfg)
      @graph = {}
      @allocs = {}
      local_info cfg
      propogate cfg
      build_graph cfg
    end

    def reg_alloc(translator, graphs)
      allocate(translator, graphs)
      Hash[@allocs.map {|vr, pr| [vr, Register.phys_reg(pr)]}]
    end

    def to_dot
      accum = "graph G {\n"
      @graph.each do |reg, neighbors|
        accum << "    #{reg.to_s} [style=filled fillcolor=\"#{COLORS[@allocs[reg] ? @allocs[reg].to_sym : "r10"]}\"]\n"
        neighbors.each {|n| accum << "    #{reg.to_s} -- #{n.to_s}\n"}
      end
      accum << "}\n"
      accum
    end

    def to_s
      @graph.map {|node, nbrs| "#{node.to_s}: #{nbrs.map {|nbr| "#{nbr.to_s}"}.join(", ")}\n"}.join
    end

    private

    def local_info(cfg)
      cfg.values.each do |graph|
        graph.blocks.each do |block|
          block.gen_set.clear
          block.kill_set.clear
          block.live_out_set.clear
          block.arm.each do |arm|
            next if Instruction.redundant(arm) || (arm.opcode == :mov && arm.body[:cond])
            arm.body[:srcs].each {|src| block.gen_set << src unless block.kill_set.include?(src) || src.immediate} if arm.body[:srcs]
            block.kill_set << arm.body[:dest] if arm.body[:dest] && !(arm.body[:srcs] && arm.body[:srcs].member?(arm.body[:dest]))
            block.kill_set += arm.body[:dests] if arm.body[:dests] && !(arm.body[:srcs] && arm.body[:srcs].member?(arm.body[:dest]))
          end
        end
      end
    end

    def propogate(cfg)
      loop do
        convergent = true
        cfg.values.each do |graph|
          graph.blocks.reverse.each do |block|
            new_los = Set[]
            block.successors.each do |succ|
              succ = succ[:block]
              new_los |= succ.gen_set | (succ.live_out_set - succ.kill_set)
            end
            convergent = false if new_los != block.live_out_set
            block.live_out_set = new_los
          end
        end
        break if convergent
      end
    end

    def to_s
      @graph.collect {|k, v| "#{k.to_s} => #{v.collect {|r| r.to_s}.join(', ')}"}
    end

    def build_graph(cfg)
      cfg.each do |name, graph|
        graph.blocks.each do |block|
          los = block.live_out_set
          block.arm.reverse.each do |arm|
            next if Instruction.redundant(arm)
            # Add sources to live out set
            los |= arm.body[:srcs].collect {|src| src if !src.immediate}.compact.to_set if arm.body[:srcs]
            if arm.opcode == :mov && arm.body[:cond]
              # conditional moves should be ignored
            elsif arm.opcode == :str
              # dest is a source
              los.add(arm.body[:dest])
            elsif arm.opcode == :pop
              # kill all pop destinations
              los = los - arm.body[:dests].to_set
            elsif arm.body[:dest]
              target = arm.body[:dest]
              los = los - Set[target]
              @graph[target] ? @graph[target] |= los : @graph[target] = los
              los.each {|src| @graph[src] ? @graph[src] << target : @graph[src] = Set[target]}
              # Note: don't know if I need to add target LOS if target in srcs, assuming not
            end
          end
          block.live_out_set = los
        end
      end
    end

    def allocate(translator, graphs)
      available = REGISTERS - SPECIAL
      orig = @graph.dup
      stack = []
      while orig.any? do
        node = (orig.find {|n, s| !n.physical && s.size <= available.size} or
                orig.find {|n, s| !n.physical} or
                orig.find {|n, _| !SPECIAL.include? n.value} or
                orig.keys)[0]
        orig.delete node
        stack.push node
      end
      while stack.any? do
        node = stack.pop
        if node.physical
          @allocs[node] = node.value
        else
          avail = available - @graph[node].collect {|nbr| @allocs[nbr]}.compact
          if avail.empty?
            translator.insert_spill(graphs, node)
          else
            @allocs[node] = avail.first
          end
        end
      end
    end
  end
end
