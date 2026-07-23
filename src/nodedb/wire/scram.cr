require "openssl"
require "openssl/pkcs5"
require "openssl/hmac"
require "digest/sha256"
require "base64"
require "random/secure"

module NodeDB
  module Wire
    # SCRAM-SHA-256 client (RFC 5802/7677) for pgwire SASL auth.
    # Username is sent empty in client-first — the server takes the user
    # from the startup message (PostgreSQL convention).
    class Scram
      GS2_HEADER = "n,,"

      @server_signature : String?

      def initialize(@user : String, @password : String,
                     @nonce : String = Random::Secure.urlsafe_base64(18))
      end

      def client_first : String
        "#{GS2_HEADER}#{client_first_bare}"
      end

      def client_final(server_first : String) : String
        attrs = parse_attrs(server_first)
        full_nonce = attrs["r"]? || raise ConnectionError.new("SCRAM: server-first missing nonce")
        salt = attrs["s"]? || raise ConnectionError.new("SCRAM: server-first missing salt")
        iterations = (attrs["i"]? || raise ConnectionError.new("SCRAM: server-first missing iterations")).to_i
        unless full_nonce.starts_with?(@nonce) && full_nonce.size > @nonce.size
          raise ConnectionError.new("SCRAM: server nonce does not extend client nonce")
        end

        salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, Base64.decode(salt),
          iterations: iterations, algorithm: OpenSSL::Algorithm::SHA256, key_size: 32)
        client_key = hmac(salted, "Client Key")
        stored_key = Digest::SHA256.digest(client_key)

        without_proof = "c=#{Base64.strict_encode(GS2_HEADER)},r=#{full_nonce}"
        auth_message = "#{client_first_bare},#{server_first},#{without_proof}"
        client_signature = hmac(stored_key, auth_message)
        proof = Bytes.new(32) { |i| client_key[i] ^ client_signature[i] }

        server_key = hmac(salted, "Server Key")
        @server_signature = Base64.strict_encode(hmac(server_key, auth_message))

        "#{without_proof},p=#{Base64.strict_encode(proof)}"
      end

      def verify_server_final(server_final : String) : Nil
        attrs = parse_attrs(server_final)
        if error = attrs["e"]?
          raise ConnectionError.new("SCRAM: server error: #{error}")
        end
        expected = @server_signature || raise ConnectionError.new("SCRAM: client_final not yet computed")
        unless attrs["v"]? == expected
          raise ConnectionError.new("SCRAM: server signature mismatch")
        end
      end

      private def client_first_bare : String
        "n=#{@user},r=#{@nonce}"
      end

      private def hmac(key, data) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end

      # "r=abc,s=xyz,i=4096" → {"r" => "abc", ...}; values may contain '='
      # (base64), so split on the first '=' only.
      private def parse_attrs(message : String) : Hash(String, String)
        message.split(',').each_with_object({} of String => String) do |part, acc|
          key, _, value = part.partition('=')
          acc[key] = value unless key.empty?
        end
      end
    end
  end
end
