module NodeDB
  module SQL
    # Timeseries helpers. NodeDB renames the TIME_KEY column to `timestamp`
    # internally and filters on epoch-ms integers.
    module Timeseries
      INTERVAL_RE = /\A\d+(us|ms|s|m|h|d|w)\z/

      def self.time_bucket(interval : String, as_alias : String = "bucket") : String
        raise ArgumentError.new("invalid interval: #{interval.inspect}") unless INTERVAL_RE.matches?(interval)
        "time_bucket('#{interval}', timestamp) AS #{Quoting.identifier(as_alias)}"
      end

      def self.epoch_ms(time : Time) : Int64
        time.to_unix_ms
      end

      def self.since_clause(time : Time) : String
        "timestamp > #{epoch_ms(time)}"
      end

      def self.until_clause(time : Time) : String
        "timestamp <= #{epoch_ms(time)}"
      end
    end
  end
end
