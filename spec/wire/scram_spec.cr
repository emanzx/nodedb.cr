require "../spec_helper"

# RFC 7677 §3 test vector (SCRAM-SHA-256, password "pencil").
RFC_CLIENT_NONCE = "rOprNGfwEbeRWgbNEkqO"
RFC_SERVER_FIRST = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
RFC_CLIENT_FINAL = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
RFC_SERVER_FINAL = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

describe NodeDB::Wire::Scram do
  it "produces client-first with empty username by default (pg convention)" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first.should eq("n,,n=,r=#{RFC_CLIENT_NONCE}")
  end

  it "produces client-first with username in RFC vector mode" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE, send_username: true)
    scram.client_first.should eq("n,,n=user,r=#{RFC_CLIENT_NONCE}")
  end

  it "computes the RFC 7677 client proof" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE, send_username: true)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST).should eq(RFC_CLIENT_FINAL)
  end

  it "verifies the RFC 7677 server signature" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE, send_username: true)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST)
    scram.verify_server_final(RFC_SERVER_FINAL) # must not raise
  end

  it "computes a well-formed client-final in default (empty username) mode" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first
    final = scram.client_final(RFC_SERVER_FIRST)
    final.should match(/\Ac=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj\)hNlF\$k0,p=[A-Za-z0-9+\/]{43}=\z/)
  end

  it "rejects a server nonce that does not extend ours" do
    scram = NodeDB::Wire::Scram.new(user: "u", password: "p", nonce: "abc")
    scram.client_first
    expect_raises(NodeDB::ConnectionError) do
      scram.client_final("r=EVIL,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
    end
  end

  it "rejects a bad server signature and error responses" do
    scram = NodeDB::Wire::Scram.new(user: "user", password: "pencil", nonce: RFC_CLIENT_NONCE)
    scram.client_first
    scram.client_final(RFC_SERVER_FIRST)
    expect_raises(NodeDB::ConnectionError) { scram.verify_server_final("v=AAAA") }
    expect_raises(NodeDB::ConnectionError) { scram.verify_server_final("e=other-error") }
  end
end
