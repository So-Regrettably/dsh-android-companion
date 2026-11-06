#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语音转文字（2026-10-28 建，10-29 换 SenseVoice 首选）

链路：插件用 ffmpeg 把 QQ 语音转成 16kHz 单声道 wav → 调这个脚本 → 写成 .txt。

用法：stt.py <wav 路径> <输出前缀>
    → 在 <输出前缀>.txt 里写转写结果（插件只认 workDir 里第一个 .txt）

引擎优先级（10-29 实测后定的）：
  1. **SenseVoice-Small int8**（239MB，sherpa-onnx）——中文最准，自带标点
  2. Paraformer-zh int8（227MB）——老引擎，回落用
  3. vosk small（42MB）——最后兜底

为什么换 SenseVoice（同一批真实 QQ 语音实测）：
  a.mp3（1.90 秒，真值「撒个娇呀宝宝」）
    Paraformer          大个叫呀宝宝      ← 用户听到的就是这个
    Paraformer + 补静音  撒个娇呀宝宝
    **SenseVoice        撒个娇呀，宝宝。**  ← 全对，还带标点
  只有 1.06 秒的 b.mp3 三个引擎都救不回来——**极短音频是硬伤**，
  这种情况宁可让上游重说，不要猜。

⚠️ 两条走过的弯路（别重犯）：
  - **音量归一化（loudnorm）反而变差**：a.mp3 上 SenseVoice 把「撒个」听成「打个」
  - **补静音对 1 秒音频有害**：b.mp3 补 0.3 秒静音后 Paraformer 直接输出空
  → 所以这里**不做任何音频预处理**，原始 wav 直接喂模型。
"""
import array
import os
import re
import subprocess
import sys
import tempfile
import wave

SV_DIR = "/root/models/sense-voice"
SV_MODEL = os.path.join(SV_DIR, "model.int8.onnx")
SV_TOKENS = os.path.join(SV_DIR, "tokens.txt")

PARA_DIR = "/root/models/sherpa-onnx-paraformer-zh"
PARA_MODEL = os.path.join(PARA_DIR, "model.int8.onnx")
PARA_TOKENS = os.path.join(PARA_DIR, "tokens.txt")

VOSK_DIR = "/root/models/vosk-model-small-cn-0.22"

_sv = None
_para = None


def fail(msg, out_base, spoken=""):
    """转写失败时的出口。

    2026-10-30 她反馈的第 3 条：转写失败时她只看到「[语音]」，不知道说了什么，
    只能反问一遍。原来这里有两处叠在一起：
      1. 写的是**空 txt** —— 就算插件读到也是空
      2. 返回 1 —— 而插件的 runProcess 是「非零退出码 = reject」，连 txt 都不读

    所以改成：写一句人话 + **返回 0**。她看到「这条语音没转出来」就知道该让人重说，
    而不是干瞪眼。真正的原因留在 stderr（前缀 FAIL），日志里能查。
    """
    text = spoken or "（这条语音没转出来，让他再说一遍吧）"
    try:
        with open(out_base + ".txt", "w", encoding="utf-8") as f:
            f.write(text + "\n")
    except Exception:
        pass
    sys.stderr.write("[stt] FAIL " + msg + "\n")
    return 0


def load_wav(path, want_sr=16000):
    """读成 float32 归一化样本；采样率不对就先用 ffmpeg 重采样。"""
    with wave.open(path, "rb") as wf:
        ch, width, sr, n = wf.getnchannels(), wf.getsampwidth(), wf.getframerate(), wf.getnframes()
        raw = wf.readframes(n)
    if ch != 1 or width != 2:
        raise RuntimeError("wav 不是 16bit 单声道 (%dch/%dbit)" % (ch, width * 8))
    if sr != want_sr:
        tmp = tempfile.mktemp(suffix=".wav")
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", path, "-ar", str(want_sr), "-ac", "1", tmp],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            with wave.open(tmp, "rb") as wf:
                raw = wf.readframes(wf.getnframes())
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return [s / 32768.0 for s in array.array("h", raw)]


def _decode(recognizer, wav_path):
    samples = load_wav(wav_path, 16000)
    stream = recognizer.create_stream()
    stream.accept_waveform(16000, samples)
    recognizer.decode_stream(stream)
    return stream.result.text


def run_sense_voice(wav_path):
    global _sv
    import sherpa_onnx

    if _sv is None:
        _sv = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=SV_MODEL,
            tokens=SV_TOKENS,
            use_itn=True,          # 逆文本归一化：数字、时间写法更自然
            num_threads=2,
            debug=False,
            language="zh",
        )
    text = _decode(_sv, wav_path)
    # 去掉 <|zh|><|NEUTRAL|><|Speech|> 这类标签，但**保留标点**
    return re.sub(r"<\|[^|]*\|>", "", text).strip()


def run_paraformer(wav_path):
    global _para
    import sherpa_onnx

    if _para is None:
        _para = sherpa_onnx.OfflineRecognizer.from_paraformer(
            paraformer=PARA_MODEL,
            tokens=PARA_TOKENS,
            num_threads=2,
            sample_rate=16000,
            feature_dim=80,
            decoding_method="greedy_search",
            debug=False,
        )
    text = _decode(_para, wav_path)
    return re.sub(r"<\|[^|]*\|>", "", text).strip()


def run_vosk(wav_path):
    import json

    from vosk import KaldiRecognizer, Model, SetLogLevel

    SetLogLevel(-1)
    model = Model(VOSK_DIR)
    with wave.open(wav_path, "rb") as wf:
        if wf.getnchannels() != 1 or wf.getsampwidth() != 2:
            raise RuntimeError("wav 不是 16bit 单声道")
        rec = KaldiRecognizer(model, wf.getframerate())
        rec.SetWords(False)
        chunks = []
        while True:
            data = wf.readframes(4000)
            if not data:
                break
            if rec.AcceptWaveform(data):
                chunks.append(json.loads(rec.Result()).get("text", ""))
        chunks.append(json.loads(rec.FinalResult()).get("text", ""))
    return "".join(chunks)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    wav_path, out_base = sys.argv[1], sys.argv[2]

    if not os.path.exists(wav_path):
        return fail("音频不存在: " + wav_path, out_base)

    # 极短音频闸门：实测 1.06 秒的语音，三个引擎都会给出一句"像话但不是话"的结果
    # （「打个妞」「八分钟」）。给错的比说没听清更有害——她会当真。
    try:
        with wave.open(wav_path, "rb") as wf:
            dur = wf.getnframes() / float(wf.getframerate() or 1)
    except Exception:
        dur = 99.0
    if dur < 1.2:
        text = "（这句只有 %.1f 秒，太短了没听清，让他再说一遍吧）" % dur
        with open(out_base + ".txt", "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(text)
        return 0

    text = ""

    # 1) SenseVoice
    if os.path.exists(SV_MODEL) and os.path.exists(SV_TOKENS):
        try:
            text = run_sense_voice(wav_path)
        except Exception as exc:
            sys.stderr.write("[stt] sense-voice 失败，回落 paraformer: %r\n" % (exc,))
            text = ""

    # 2) Paraformer
    if not text and os.path.exists(PARA_MODEL) and os.path.exists(PARA_TOKENS):
        try:
            text = run_paraformer(wav_path)
        except Exception as exc:
            sys.stderr.write("[stt] paraformer 失败，回落 vosk: %r\n" % (exc,))
            text = ""

    # 3) vosk
    if not text and os.path.isdir(VOSK_DIR):
        try:
            text = run_vosk(wav_path)
        except Exception as exc:
            return fail("三个引擎都失败: %r" % (exc,), out_base)

    text = text.strip()
    # 引擎"成功"但吐空：同样是静默，照样给她一句话（见 fail 的说明）
    if not text:
        text = "（这条语音没转出来，让他再说一遍吧）"
        sys.stderr.write("[stt] FAIL 三个引擎都没吐出内容\n")
    with open(out_base + ".txt", "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
