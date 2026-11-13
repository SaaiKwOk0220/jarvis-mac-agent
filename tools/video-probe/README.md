# Synthetic video frame probe

This standalone development experiment generates its own two-second red/blue video; it does not accept user video, inspect the screen, access a browser, or process audio. It is not connected to Jarvis. It uses AVFoundation with `AVAssetReferenceRestrictions.forbidAll`, requests frames at 0.25 and 1.25 seconds with zero time tolerance, constrains output to 160×160, and checks the expected color swap. All generated files are in a temporary directory removed after use.

On macOS with Xcode selected, run `python3 -B video_probe.py`. This does not contact a model. AVFoundation may need access to system media services; some sandbox environments cannot run it. Unit tests: `python3 -B -m unittest -v test_video_probe`.

To explicitly send the two synthetic images to a **trusted** existing Ollama service, run `python3 -B video_probe.py --model qwen2.5vl:3b --port 11434`. This never starts or downloads a model. The endpoint is fixed to IPv4 loopback, but the service itself may forward images; loopback alone is not proof of local-only inference. Response size is limited and redirects fail.

The asset reference setting restricts external media references, but does not establish system-wide network isolation of AVFoundation/XPC services or bound decoder-internal memory. The timeout controls the directly invoked Swift process, not arbitrary descendants. The experiment handles only generated media and must not be adapted for real user video or considered a production security boundary without further work. Frame order and the model's answer are not automatically evaluated for correctness.
