# Twisterminigen Privacy Notice

Twisterminigen performs prompt processing, image generation, OCR checks, gallery storage, and
recipe management locally on the Mac. It has no account system, advertising, analytics, tracking,
or telemetry upload. Prompts, images, recipes, performance samples, model paths, and the local Krea
license-acceptance receipt remain in app-owned or user-selected local storage.

Network access occurs only after an explicit download action. The app downloads pinned model,
LoRA, or upscaler files from the source shown in the UI (currently Hugging Face or GitHub-hosted
artifacts). Those hosts receive ordinary network metadata such as the device's IP address. The app
does not attach prompts, generated images, gallery data, or local telemetry to those requests.

The privacy manifest declares no tracking and no collected data. Required-reason API declarations
cover app-only UserDefaults, metadata for app-owned and explicitly selected files, elapsed-time
measurement, and disk-capacity checks that prevent unsafe downloads or writes. Values derived from
those APIs are not transmitted by Twisterminigen.

Krea safety screening is deterministic and local. It examines text immediately before a render;
the prompt and screening result are not sent to Krea or a moderation service. Generated outputs
remain local until the user explicitly exports them. Every user-facing export path requires an
affirmative review of the generated pixels and adds PNG AI-disclosure metadata with the producing
app build, model reference, source generation ID, and transformation. Review confirmations are
single-use and bound locally to the exact final PNG SHA-256, export kind, transformation, and
output count. Batch review is per-image: every exact final PNG is displayed and explicitly marked
Reviewed in order before a receipt exists, so an off-screen item cannot inherit another image's
confirmation. Derived results are previewed after processing and before publication; cancelled
reviews publish nothing. Finder/full-size actions receive reviewed copies rather than managed
originals. “Export with recipe” additionally binds a portable sidecar to the exported PNG's
SHA-256 and byte count. User-selected export paths are resolved before publication; private app,
cache, model, and default or custom Gallery roots are rejected. Publication is exclusive,
no-overwrite, and based on a fsynced sibling temporary file. The destination becomes visible only
through atomic `RENAME_EXCL`; there is no direct-write fallback, and unsupported filesystems fail
before destination visibility. The staging descriptor remains open across rename. Twisterminigen
reopens the destination without following symlinks, matches its device/inode to that descriptor,
compares every byte and a full SHA-256 with the reviewed payload, and confirms that the parent path
still names the same open directory before reporting success. A mismatch is not confirmed and is
never rolled back or unlinked. A later close or parent-directory fsync failure is returned as a
warning that the exact reviewed file is visible but its durability could not be confirmed. Before
visibility, failed staging content is scrubbed to zero through its open descriptor and the hidden
zero-byte tombstone is left in place, avoiding a pathname-delete race. If that scrub cannot be
confirmed, the state is reported as unknown. Local AI 4× inference receives verified PNG bytes and
returns encoded PNG bytes in memory; it creates no production source/output temporary path.
Sequential batch and PNG-plus-recipe APIs preserve explicit per-destination states—durable, visible
with a durability warning, failed before visibility, unknown, or unattempted after an earlier
failure—and Gallery/System display every full destination path and state, so a visible result is
never reported as absent.
