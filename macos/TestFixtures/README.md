# Shared portal fixtures

`Portal/` contains synthetic HTML and JSON used by the native portal and engine
tests. The JavaScript executor tests read the same `field_descriptors.json`
corpus as the Swift intent tests, so both consumers must agree on its meanings.

These fixtures were moved unchanged from the archived v1 baseline. They are
maintained regression inputs, not live venue evidence or shipped resources.
Keep captures and credentials out of this directory. Production schema, provider
profiles and correction rules have one canonical copy in `macos/Resources`.
