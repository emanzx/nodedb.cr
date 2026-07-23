require "db"

module NodeDB
  class Error < ::DB::Error
  end

  class ConnectionError < Error
  end

  class QueryError < Error
    getter sqlstate : String?

    def initialize(message : String, @sqlstate : String? = nil)
      super(message)
    end
  end
end
