module Zipping
  class DOSTime
    def initialize(time)
      @t = time
    end

    def dos_time
      (@t.sec >> 1) |
        (@t.min << 5) |
        (@t.hour << 11)
    end

    def dos_date
      @t.day |
        (@t.month << 5) |
        ((@t.year - 1980) << 9)
    end
  end
end
