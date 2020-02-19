module Zipping
  class Deflater
    attr_reader :size, :crc

    def initialize(out)
      @o = out
      @deflater = Zlib::Deflate.new Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS
      @size = 0
      @crc = Zlib.crc32
    end

    def <<(data)
      @deflater << data
      @o << @deflater.flush
      @size += data.bytesize
      @crc = Zlib.crc32 data, @crc
      self
    end

    def finish
      @o << @deflater.finish
      self
    end
  end
end
