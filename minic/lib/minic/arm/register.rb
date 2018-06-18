require 'minic/llvm'

module Minic::ARM
  class Register
    attr_reader :value, :immediate, :physical
    attr_accessor :defined, :uses

    VALID_IDS = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "fp", "lr", "sp", "pc"].freeze

    # Note: Reflection here makes this general-purpose Register constructor very useful.
    #       This is probably the only place reflection is used in this codebase
    def self.reg(from)
      if from.is_a? Minic::LLVM::Register
        if from.immediate
          Register.new(from.immediate.to_i, true, false)
        else
          Register.new(from.name, false, false)
        end
      elsif from.is_a? String
        Register.new(from, false, false)
      elsif from.is_a? Integer
        Register.new(from, true, false)
      elsif from.is_a? Register
        from
      elsif from.is_a? Array
        from.map {|f| reg(f)}
      else
        raise "cannot create virtual register from #{from.nil? ? 'nil' : from}"
      end
    end

    def self.phys_reg(value, immediate=false)
      VALID_IDS.include?(value) or raise "cannot create physical reg with id #{value}"
      Register.new(value, immediate, true)
    end

    def initialize(value, immediate, physical)
      @value = value
      @immediate = immediate
      @physical = physical
      @defined = nil
      @uses = []
    end

    # needed for simple comparisons
    def ==(o)
      o.class == self.class && o.state == state
    end

    # needed for set comparisons
    def eql?(o)
      o.class == self.class && o.state == state
    end

    # needed for set comparisons, note that this equates register hashes with same state
    def hash
      self.state.hash
    end

    def state
      [@value, @immediate, @physical]
    end

    alias name value

    def to_s
      if @immediate
        "##{@value.to_s}"
      else
        "#{@physical ? "" : "v"}#{@value}"
      end
    end
  end
end
