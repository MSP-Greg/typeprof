module TypeProf
  class CodePosition
    def initialize(lineno, column)
      @lineno = lineno
      @column = column
    end

    attr_reader :lineno, :column

    def <=>(other)
      cmp = @lineno <=> other.lineno
      cmp == 0 ? @column <=> other.column : cmp
    end

    include Comparable

    def to_s
      "(%d,%d)" % [@lineno, @column]
    end

    alias inspect to_s
  end

  class CodeRange
    def initialize(first, last)
      @first = first
      @last = last
    end

    attr_reader :first, :last

    def include?(pos)
      @first <= pos && pos < @last
    end

    def to_s
      "%p-%p" % [@first, @last]
    end

    alias inspect to_s

    def ==(other)
      @first == other.first && @last == other.last
    end
  end
end