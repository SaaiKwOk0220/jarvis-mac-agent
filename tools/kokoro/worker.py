"""Runs only in the experimental sandbox, receiving test text via stdin."""
import sys
import numpy as np
from mlx_audio.tts.utils import load_model

model = load_model(sys.argv[1])
text = sys.stdin.read(1201)
for segment in model.generate(text=text, voice='zf_xiaobei', lang_code='z'):
    audio = np.asarray(segment.audio).reshape(-1)
    sys.stdout.buffer.write(np.asarray(np.clip(audio, -1, 1) * 32767, dtype='<i2').tobytes())
    sys.stdout.buffer.flush()
