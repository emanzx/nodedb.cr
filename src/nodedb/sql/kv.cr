module NodeDB
  module SQL
    # KV engine helpers. Deliberately only set_ttl — matches nodedb-ruby's lib.
    module KV
      def self.set_ttl(table : String, key : String, ttl : Int32) : String
        "UPDATE #{Quoting.identifier(table)} SET ttl = #{ttl} WHERE key = #{Quoting.string(key)}"
      end
    end
  end
end
