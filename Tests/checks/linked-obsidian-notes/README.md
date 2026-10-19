# Linked Obsidian notes

Run `python3 -B Tests/checks/linked-obsidian-notes/run.py OUTPUT_DIRECTORY` from the repository root. Use a storage-routed development archive for the output directory. Xcode must be installed at `/Applications/Xcode.app`.

The check compiles the production canvas model, store, and relay against Apple's SDK. It uses PencilKit drawings, an isolated application home, and a controlled URL loading boundary. It does not read the user's vault or contact the live relay.

Assertions cover old scene decoding, path and SHA validation, attaching a Markdown source, compare-and-swap writes, typing during a write, conflict and missing-source handling, stale editor and connection responses, scene replacement, overlapping reads, cache refresh, and preservation of ink provenance and layout. The result records source hashes before and after execution.

Linked notes keep at most 512 UTF-8 bytes of display text, marked when truncated. The editor keeps the full source. Size-limit checks verify that valid large notes remain restorable and an oversized scene cannot replace the last restorable save. Ordered reads and source binding are checked across editor recovery and polling. Obsolete read failures cannot block a successful save or a newer accepted read. Dirty-state and save acknowledgements use exact UTF-8 bytes, including normalization-only changes.

These checks do not establish installed iPad UI acceptance, Pencil gesture parity, or recovery of an unsaved draft after the app process exits.
