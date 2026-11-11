# Exact browser experiment

Build with `scripts/build-dev-app.sh --exact-experiment <output-directory>`. The resulting app has a separate bundle identity and uses `~/Library/Application Support/Jarvis-Browser-Experiment`. The exact-address feature is off unless the isolated experimental build is launched with `JARVIS_EXACT_BROWSER_OPT_IN=1`. A normal build cannot enable it through that variable. Misconfigured experimental identities stop before the instance lock and database are opened.

Approval covers only the initial URL; the browser can redirect, run scripts and make additional requests. Full addresses may contain secrets and are presented for review. Original task text may be stored locally. The transient ticket expires and is not a substitute for reviewing the displayed destination.

The GRDB privacy resource is placed under `Contents/Resources` for strict signing. SwiftPM's generated accessor currently searches the bundle root or a build-time path; the present GRDB production sources do not call it. Recheck this packaging assumption when updating GRDB or SwiftPM.
