# HOLD — runner disabled

The runner deliberately fails closed and does not launch the helper. Prior versions could not reliably clean descendants without risking unrelated processes. The details below describe the previous experiment, not current runnable behavior. Do not distribute or use this tool.

# Kokoro isolated experiment

This is a developer experiment, disabled and unconnected to Jarvis. Use only fixed, nonsensitive test text. It requires macOS, Apple Silicon with Metal, `/usr/bin/sandbox-exec`, an independently installed Python environment containing mlx-audio and misaki[zh], and a local Kokoro model directory. Model/runtime are not bundled and no download is performed. Check their provenance, licenses, and versions before use.

Run tests: `python3 -m unittest discover -s tools/kokoro -v`.

For a local test (replace both paths with your own), send text on stdin and consume the raw PCM on stdout; the following counts bytes without saving audio:

```sh
printf '你好，我是贾维斯。' | python3 tools/kokoro/run.py --python /path/to/venv/bin/python --model /path/to/kokoro-model | python3 -c 'import sys; print(len(sys.stdin.buffer.read()))'
```

Output is signed 16-bit little-endian, mono, 24000 Hz. Input is limited to 300 characters and output to 2 MB; the launcher buffers the output in memory, returns only on success, limits execution time, and kills/reaps the helper on failure or SIGINT/SIGTERM. stderr from the helper is discarded. No input text is passed via command-line arguments or deliberately logged. The helper may create a fixed jieba dictionary cache inside its private temporary directory, which is removed on normal exit, timeout and handled termination; abrupt termination such as SIGKILL or a machine crash can leave it behind. No cleanup promise extends to those cases. No user audio is deliberately written to disk.

The sandbox denies `network*` and file writes except the private temp directory. It intentionally allows reads and other macOS operations; pre-opened file descriptors, IPC and system services are not comprehensively isolated. This is not a general privacy or security boundary. The externally supplied Python and model must be trusted. Access to Metal may require running outside a host-level sandbox; if unavailable, the command fails instead of falling back to networking. Runtime dependencies could attempt prohibited writes or network access and fail. Only short synthetic text and the above TCP/write tests have been evaluated; audio quality, robust streaming, application playback, arbitrary text, complete offline behavior, and safe deployment are not established.

The runtime must be trusted: a malicious descendant can call `setsid()` to escape the helper process group, use allowed IPC or read accessible files; this prototype cannot contain it. The temporary directory has no disk quota, so the helper can exhaust local storage. The timeout starts after reading stdin and starting the child; an unclosed or stalled stdin can block indefinitely. Process-group termination is best effort and does not establish ownership of unrelated processes in the event of process-group ID reuse. Do not use this as a production security boundary.
