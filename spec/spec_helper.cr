require "spec"
require "../src/nodedb"

# Integration gate: yields an open DB::Database only when NODEDB_URL is set,
# otherwise marks the example pending. Usable from any *_spec.cr.
def with_nodedb(&)
  url = ENV["NODEDB_URL"]?
  pending! "NODEDB_URL not set — integration spec skipped" unless url
  DB.open(url) do |db|
    yield db
  end
end
