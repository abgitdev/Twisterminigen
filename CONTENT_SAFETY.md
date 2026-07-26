# Twisterminigen Content Safety

Twisterminigen uses a local, defense-in-depth content filter for its single-user, on-device Krea 2
deployment. It does not upload prompts or images to a moderation provider.

Before every render entry point—Generate, Queue, Regional prompts, presets, and App Intents—the app
screens requested positive text, exact lettering, and regional prompts for
high-confidence indicators of child sexual exploitation, non-consensual intimate imagery,
deceptive impersonation or election interference, weapons development or mass surveillance,
fraud or false engagement, credible threats, explicit pornography, and attempts to bypass safety
controls. Negative prompts are exclusions and are deliberately not treated as requested output.
A finding blocks the recipe before model execution and links the user to the Krea 2 Acceptable Use
Policy. The same runtime validation is applied again when queued or programmatic recipes execute.

Prompt screening cannot determine every property of generated pixels. Therefore every
user-facing distribution path—including single, paired-recipe, bulk, save-copy, drag-and-drop,
transparent cut-out, local AI 4×, and Finder-copy exports—requires the user to
affirm that the visible output was reviewed and is lawful, safe, and policy-compliant. Exported
PNGs contain an AI disclosure, producing app build, model reference, source generation IDs, and a
reminder that review is required. The confirmation is single-use and cryptographically bound to
the exact final PNG SHA-256, transformation, export kind, and output count; changing any of them
invalidates publication. A multi-image operation displays the exact final PNGs one at a time in
receipt order and requires an explicit Reviewed action for every item. There is no bulk checkbox
or authorization for an off-screen item, and cancelling any item issues no receipt. Before a PNG
can enter this boundary, its complete chunk structure and
CRC values are validated and the disclosure, source IDs, and exact transformation must be real,
unique metadata chunks—not matching bytes hidden in pixels or appended after the PNG. Cut-outs and
local AI 4× results are visibly previewed only after their final pixels exist and before that bound
confirmation is issued. Derived PNGs identify their transformation. Export and full-size actions
prepare reviewed provenance copies. Gallery “Show in Finder” and “Open Gallery folder” are
read-only navigation to existing managed originals; they do not copy, rewrite, or publish bytes.
External publication rejects app-managed,
cache, model, Gallery (including an injected custom Gallery root), and symlink destinations. It
writes and fsyncs a private sibling, then makes the destination visible only through an atomic
`RENAME_EXCL`; there is no direct-write or exclusive-create destination fallback. A filesystem
without exclusive rename fails before the destination becomes visible. The reviewed staging
descriptor stays open across rename. Before success is reported, the destination is reopened with
`O_NOFOLLOW`, its device/inode identity is matched to that descriptor, every byte and a full SHA-256
are compared with the reviewed payload, and the parent pathname is checked before and after rename
against the same open directory identity. A mismatch is reported as not confirmed and is never
rolled back or pathname-deleted. Once exact visibility is confirmed, the parent directory is
fsynced; a close or directory-fsync failure is reported as a visible-file durability warning.
Before visibility, failed staging content is truncated and fsynced through its still-open
descriptor. Its hidden zero-byte tombstone is left in place instead of pathname-deleting a name
another process could replace; failure to confirm that scrub is reported as an unknown state. Local
AI 4× accepts verified PNG bytes and returns encoded PNG bytes entirely in memory, so inference has
no production source/output temporary pathname to clean up or race. If a sequential batch is
interrupted by a destination race, the result preserves every URL already published and names the
failed and unattempted items; the UI never reports the whole batch as failed or silently discards
the partial list. Every attempted destination has an explicit state: durably published, visibly
published with a durability warning, failed before visibility, or—when staging cleanup or exact
destination/path binding cannot be confirmed—unknown. PNG-plus-recipe export reports both
destination states and preserves a reviewed
PNG that became visible before a recipe race or failure. Gallery and System render a scrollable row
for every exact destination, including its full path and simultaneous warnings, failures,
not-confirmed states, and unattempted states.
Portable recipe sidecars additionally bind provenance to the exported PNG digest and byte count.

This system intentionally favors high-confidence blocking plus mandatory human review over a
broad keyword filter that would block documentary, medical, historical, or benign artistic work.
It is a mitigation, not a guarantee. Users remain responsible for the Krea 2 Community License,
Acceptable Use Policy, applicable law, and destination-platform rules.
