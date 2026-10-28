#!/usr/bin/env python3
"""生成下载完成提示音 Resources/done.wav：上行纯五度「叮—咚」（G5 → D6），玻璃质感，约 0.9 秒。
音色：基频 + 略不谐和的高泛音（像钢片琴 / 马林巴），快起音、指数衰减；第二个音稍响稍长，听着是「完成」。
改音色改这里的参数，重新跑：python3 script/make_done_sound.py"""
import os, wave
import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def bell(freq, dur, amp):
    t = np.arange(int(SR * dur)) / SR
    partials = [(1.0, 1.0, 3.2), (2.0, 0.42, 5.5), (3.01, 0.18, 8.0), (4.17, 0.08, 11.0)]  # (倍频, 相对音量, 衰减速度)
    y = sum(a * np.sin(2 * np.pi * freq * m * t) * np.exp(-d * t) for m, a, d in partials)
    attack = np.minimum(t / 0.004, 1.0)  # 4 毫秒起音，不爆音
    return amp * y * attack


def main():
    total = 0.95
    out = np.zeros(int(SR * total))
    for start, freq, dur, amp in [(0.0, 783.99, 0.55, 0.55), (0.14, 1174.66, 0.81, 0.7)]:  # G5, D6
        s = bell(freq, dur, amp)
        i = int(SR * start)
        out[i:i + len(s)] += s[:len(out) - i]
    fade = int(SR * 0.08)
    out[-fade:] *= np.linspace(1, 0, fade)
    out = out / np.max(np.abs(out)) * 0.6  # 留余量，不刺耳
    path = os.path.join(ROOT, "Resources", "done.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((out * 32767).astype(np.int16).tobytes())
    print(path)


main()
