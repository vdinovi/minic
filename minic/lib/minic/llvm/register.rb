module Minic::LLVM
  class Register
    attr_accessor :name, :type, :global, :immediate, :defined, :uses
    @@reg_count = 0

    def self.alloc(type)
      name = "r#{@@reg_count}"
      @@reg_count += 1
      Register.new(name: name, type: type)
    end

    def self.name(name, type)
      Register.new(name: name, type: type)
    end

    def self.immediate(value, type="i32")
      Register.new(name: nil, type: type, immediate: value.to_s)
    end

    def self.phi
      name = "r#{@@reg_count}"
      @@reg_count += 1
      Register.new(name: name)
    end

    def self.reset_counter
      @@reg_count = 0
    end

    def initialize(name:, type: nil, immediate: nil)
      @name = name
      @type = type
      @global = false
      @immediate = immediate
      @defined = nil
      @uses = []
    end

    def ==(other)
      self.class == other.class && ((@immediate && @immediate == other.immediate) || @name == other.name)
    end

    def to_s
      @immediate ? @immediate : (@global ? "@#{@name}" : "%#{@name}")
    end
  end
end
