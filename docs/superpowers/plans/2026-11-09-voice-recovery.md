# Voice recovery and multi-turn reliability

1. Capture regression tests for failed submission followed by a separate voice turn, preservation and recovery of failed input, manual draft editing and cancellation. Keep failed input separate from the active draft; never automatically submit manually edited content.
2. Implement a recoverable failed-input slot and explicit restore affordance; start subsequent turns with an independent empty input. Keep cancellation recoverable and do not overwrite edited drafts.
3. Test recognition revisions, partial-to-final transitions and delayed callbacks. Preserve user edits and confirmed segments without assuming all recognition partials are append-only.
4. Diagnose second-turn silence detection with deterministic sample tests and lifecycle tests; fix demonstrable cause without claiming that threshold detection is universally reliable.
5. Run targeted tests and complete Swift suite; obtain independent QA and review. Verify on device before claiming microphone behavior is fixed.
