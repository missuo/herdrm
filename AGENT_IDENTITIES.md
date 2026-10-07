# Saved agent identities

HerdrM preserves locally named agents when runtime detection temporarily disappears,
including after reopening the app. A saved agent keeps its declared kind and name in
the Agents section while its original terminal still exists. The row says **Saved ·
Not detected**, and its runtime status remains unknown. Selecting it attaches to the
existing pane; persistence never starts or restarts a process.

This feature applies to the primary Local device. SSH, Tailcat and named local
sessions keep their server-owned behavior. The declared kind accepts any kind
reported by herdr; it is independent of current runtime detection.

## Storage and matching

Records live in `~/.config/herdr/agent-reconcile.json`, using a version-1 JSON object
with a `targets` array. Each identity owns `name`, `kind`, `tab_label`, `cwd`,
`pane_id`, `tab_id`, `terminal_id` and `workspace_id`. Unknown root and target fields
are preserved without interpretation, including any external launch or credential
settings. The feature creates no launch policy or credential data.

An existing terminal ID is authoritative: a replacement terminal reusing the pane
ID never inherits its saved identity. Older records without a terminal ID are
matched by pane ID, then unambiguous tab ID, then unambiguous working directory and
label. Successful matches persist the current terminal identity, pane and directory.
A server-declared name can explicitly rebind a moved agent to its current terminal;
saved metadata alone cannot authorize that move. A pane belonging to another named
agent is never claimed. Missing or ambiguous identities do not create phantom rows.

New local agents save their identity before `agent.start`. A failed start remains
inspectable if its identity was committed. Closing a pane or workspace through
HerdrM removes the captured identities after the server confirms the close, even
when a concurrent refresh has already removed the live pane. Removal uses the
captured terminal identity, so a same-name replacement is retained; name fallback
only applies to legacy records without a terminal identity. Closing a terminal
outside HerdrM leaves the record dormant; it cannot match a replacement terminal.

Files are limited to 64 KiB, privately owned and protected against symbolic links,
hard links and unsafe permissions. The registry, lock and parent directory reject
extended ACL grants, including inherited grants; deny-only ACLs remain accepted.
Original deny-only file ACLs are copied to the replacement inode; unsafe grants
are rejected rather than stripped. Writes use a separate advisory lock and atomic
replacement; unknown extensions should use the same write lock when editing the
registry. Missing directories are created privately. Invalid registries are reported
without replacing existing data. Missing or null optional identity fields remain
compatible with older records; supplied fields with invalid types or blank values
are rejected rather than downgraded to legacy matching.
The commit callback runs immediately after atomic
replacement, so a later durability error cannot classify the identity as unsaved.

No service restart or data migration command is required. Old version-1 records are
read lazily on a normal refresh. Other schema versions fail closed. To disable the
feature by reverting the code, the inert registry may remain; do not delete unknown
extension settings as part of a code rollback.

## Validation

`ManagedAgentRegistryTests` cover reloads, arbitrary future kinds, unknown-field
preservation, unambiguous matching, terminal moves/reuse, independent identities,
explicit removal, malformed identity fields, ACL grants/inheritance, unsafe storage
and concurrent replacement. The post-rename failure
test verifies that committed state is reported before a later durability failure.
`ManagedAgentIdentityStoreTests` cover adoption, store recreation, rebinds, additional
agents, removal and opaque extension-field preservation.

The normal hosted test target can be compiled with `xcodebuild build-for-testing`.
Running hosted tests starts the app's existing lifecycle; use an isolated environment
when performing live integration acceptance. The source-only registry/store tests
can run in a standalone Swift package without starting HerdrM or a herdr daemon.
