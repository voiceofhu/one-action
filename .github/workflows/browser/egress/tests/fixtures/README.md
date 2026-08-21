# Egress installer fixture templates

These JSON files are strict manifest templates, not published release evidence.
The fake curl transport recalculates the amd64 fixture binary's `size` and
`sha256` when a test serves a manifest, and generates the matching
`SHA256SUMS`. This keeps the executable fixture's `version` behavior and the
manifest/checksum contract coupled without embedding a stale checksum after a
fixture edit.

The arm64 entries are schema-only examples; installer lifecycle tests select
the host-injected amd64 entry and do not execute or install an arm64 fixture.
