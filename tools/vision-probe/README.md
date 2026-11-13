# Local image vision probe

An experiment for **one non-sensitive image the user chooses**, using an Ollama server and model the user trusts. It does not read the browser or screen, sample video/audio, or integrate with Jarvis. The image and question are sent to the configured Ollama process at `127.0.0.1`; the tool does not persist or log them. Loopback restricts only this tool’s direct connection: the server or model may proxy requests or access a network, so it does not prove local inference or offline operation. Ollama and the operating system have their own data and logging policies.

Use a locally installed **image-capable** Ollama model, explicitly named by the user. Ensure Ollama is running, then for example:

```sh
printf '%s' '请描述图片中可见的内容。' | python3 tools/vision-probe/vision_probe.py /path/to/image.png --model YOUR_VISION_MODEL
```

`ollama list` shows installed models; `ollama pull MODEL_NAME` downloads a chosen compatible model when network access is available. A successful response does not prove a model actually understood the image: verify with a known fixture. Symbolic links are followed and the resolved target must be a regular file. Only files up to 10 MiB with PNG/JPEG signatures are accepted; signatures do not establish that the entire image decodes correctly. Ollama may reject malformed files. Set `--port` only for a local Ollama instance; redirects are rejected.

Model names are limited to 256 characters. Questions arrive on standard input (maximum 8,000 characters) and the model answer is printed to standard output after terminal control sequences and Unicode controls are removed (newlines are retained). Do not use sensitive prompts or images unless you intend to give them to the local model; shell redirection or external logging can retain output. Errors do not include the question, image, or server response body.

Run tests with `python3 -m unittest discover -s tools/vision-probe -v`. The local HTTP integration test skips if the execution environment denies loopback listening; mocked transport tests do not establish that an actual vision model works.
