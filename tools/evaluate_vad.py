#!/usr/bin/env python3
"""Offline synthetic-speech comparison. Requires numpy and onnxruntime; never uploads audio."""
import argparse
import json
import subprocess
import tempfile
import time
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort


def run(model, voice, rate):
    with tempfile.TemporaryDirectory(prefix="jarvis-vad-") as folder:
        aiff, wav = Path(folder) / 'speech.aiff', Path(folder) / 'speech.wav'
        subprocess.run(['say', '-v', voice, '-r', str(rate), '-o', str(aiff), '你好，我是贾维斯。今天我们来测试语音识别。'], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
        with wave.open(str(wav), 'rb') as f:
            if f.getframerate() != 16000 or f.getnchannels() != 1 or f.getsampwidth() != 2:
                raise ValueError('expected 16 kHz mono PCM16')
            speech = np.frombuffer(f.readframes(f.getnframes()), dtype='<i2').astype(np.float32) / 32768
        if len(speech) < 1600 or np.max(np.abs(speech)) < 0.001:
            raise ValueError('system voice produced empty audio; check voice availability and permissions')
        session = ort.InferenceSession(model, providers=['CPUExecutionProvider'])
        results = []
        for gain, noise in [(1, 0), (0.1, 0), (1, 0.01)]:
            rng = np.random.default_rng(42)
            signal = np.concatenate([speech * gain, np.zeros(64000, np.float32)])
            signal += rng.normal(0, noise, len(signal)).astype(np.float32)
            state = np.zeros((2, 1, 128), np.float32); context = np.zeros((1, 64), np.float32)
            probabilities, levels = [], []
            start = time.perf_counter()
            for pos in range(0, len(signal)-511, 512):
                block = signal[pos:pos+512]
                out, state = session.run(None, {'input': np.concatenate((context, block[None,:]), axis=1), 'state': state, 'sr': np.array(16000, np.int64)})
                context = block[-64:][None,:]
                probabilities.append(float(out[0,0])); levels.append(float(np.sqrt(np.mean(block**2))))
            elapsed = time.perf_counter() - start
            def endpoint(values, threshold):
                active = False; quiet = 0
                for i, value in enumerate(values):
                    if value >= threshold: active = True; quiet = 0
                    elif active:
                        quiet += 1
                        if quiet * .032 >= 3.5: return round((i+1)*.032, 3)
                return None
            results.append({'gain': gain, 'noise_std': noise, 'speech_seconds': len(speech)/16000, 'silero_endpoint_seconds': endpoint(probabilities, .5), 'rms_endpoint_seconds': endpoint(levels, .015), 'inference_rtf': elapsed / (len(probabilities)*.032), 'max_probability': max(probabilities)})
        return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--voice', default='Tingting')
    parser.add_argument('--rate', type=int, default=180)
    args = parser.parse_args()
    print(json.dumps(run(args.model, args.voice, args.rate), ensure_ascii=False, indent=2))
