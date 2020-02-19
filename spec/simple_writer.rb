class SimpleWriter
  def initialize(out)
    @out = out
  end

  def <<(data)
    @out << data
  end
end
