# Safari accessibility reading: experimental QA

Safari reading is disabled unless the app process is started with `JARVIS_EXPERIMENTAL_SAFARI_READ=1`. This switch is for local QA, not a release setting. Run from the package directory:

```sh
JARVIS_EXPERIMENTAL_SAFARI_READ=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run JarvisMenuBar
```

Use a public or disposable HTTPS page with no personal information. Grant Accessibility permission only when testing, and revoke it afterward if no longer wanted. Ask Jarvis to read the current Safari page; when prompted, focus that Safari window. Inspect the entire captured URL, including its query, in the approval preview before approving. Return to that same window within 15 seconds after approval. Test reject, cancel, timeout, changed URL, different Safari window, app restart and permission denial. Inspect local audit records for absence of the full URL path/query and page text.

The result is accessibility text, which may include off-screen content and is sent to the model; the model may retain or repeat it. The original user message and task title may also be stored. The feature reads a dynamic page rather than an atomic snapshot: checks compare the Safari process, launch time, window and URL before and after, but cannot prove that a page did not change and return to the same URL (ABA). No claim of document-atomic identity or of protection from prompt injection is made. Do not enable for sensitive pages. UI preview of a query string is intentional; verify the URL does not appear in audit or request records.

The capture timeout and traversal limits are best effort; external AX calls and OS scheduling are not hard real-time guarantees. The switch remains off for production until real-device QA and an independent security review have passed.
