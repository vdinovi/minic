
module Minic::Errors

  def warning(msg, line)
    puts "Compile Warning (line #{line or '?'}): #{msg}"
  end

  class ASTError < StandardError
    # Used to handle errors related to the JSON AST
    # received from the provided frontend (missing fields, etc)
    def initialize(msg="", obj)
      super("ASTError: #{msg} (#{obj})")
    end
  end

  # Errors from TypeChecker
  class TypeError < StandardError
    def initialize(msg="no message :/", line)
      super("Type Error (line #{line or '?'}): #{msg}")
    end
  end

  # Errors from CFG
  class CFGError < StandardError
    def initialize(msg="no message :/", obj)
      super("CFG Error: #{msg} (#{obj})")
    end
  end

  # Generic compile errors
  class CompileError < StandardError
    def initialize(msg="no message :/")
      super("Compile Error: #{msg}")
    end
  end

  class TranslationError < StandardError
    def initialize(msg="no message :/", obj)
      super("Instruction Translation Error: #{msg} (#{obj})")
    end
  end
end

