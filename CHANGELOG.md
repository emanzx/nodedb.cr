# Changelog

## 0.1.0 — 2026-07-23

Initial release.

- crystal-db driver for the `nodedb://` scheme (pgwire simple query protocol,
  trust + SCRAM-SHA-256 auth, NodeDB >= 0.4.0).
- SQL builders: Vector, Graph, FTS, KV, Timeseries, Spatial, Collection —
  ported from nodedb-ruby with typed args and internal quoting.
  - `Vector` includes `create_index` / `drop_index` (added during
    implementation: `SEARCH ... USING VECTOR(...)` returns no rows without a
    vector index bound to the target column — see docs/wire-facts.md).
- Schema introspection (DESCRIBE / SHOW COLLECTIONS) and text-format TypeMap
  (vectors, JSON, timestamps).
  - `TypeMap.parse_vector` (added during implementation: NodeDB 0.4.0 serves
    `FLOAT[]` columns as OID 25 text containing a JSON array of stringified
    floats, not a native array/vector wire type — this helper decodes it).
