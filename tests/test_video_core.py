from pathlib import Path
from types import SimpleNamespace
import os
import shutil
import subprocess

import pytest
from video_core import (
    build_final_ffmpeg_command,
    build_tts_audio_config,
    create_tts,
    create_tts_offline,
    sentences,
    write_srt,
)


class FakeTTSClient:
    def __init__(self):
        self.calls = []

    def synthesize_speech(self, input, voice, audio_config):
        self.calls.append(
            {
                "input": input,
                "voice": voice,
                "audio_config": audio_config,
            }
        )
        return SimpleNamespace(audio_content=b"fake-mp3")


def test_sentences_splits_script_into_sentence_units():
    assert sentences("Hello world. How are you? Great!") == [
        "Hello world.",
        "How are you?",
        "Great!",
    ]


def test_build_tts_audio_config_keeps_voice_modulation_values():
    audio_config = build_tts_audio_config(speaking_rate=1.15, pitch=-2.5)

    assert audio_config.speaking_rate == 1.15
    assert audio_config.pitch == -2.5


def test_create_tts_writes_mp3_and_uses_selected_voice_settings(tmp_path):
    fake_client = FakeTTSClient()
    output = tmp_path / "narration.mp3"

    create_tts(
        "Sample narration",
        output,
        "en-IN-Neural2-B",
        speaking_rate=0.95,
        pitch=3.0,
        tts_client=fake_client,
    )

    assert output.read_bytes() == b"fake-mp3"
    assert len(fake_client.calls) == 1
    call = fake_client.calls[0]
    assert call["input"].text == "Sample narration"
    assert call["voice"].name == "en-IN-Neural2-B"
    assert call["audio_config"].speaking_rate == 0.95
    assert call["audio_config"].pitch == 3.0


def test_write_srt_generates_sequenced_caption_blocks(tmp_path):
    output = tmp_path / "subtitles.srt"

    write_srt(["First line", "Second line"], 8.0, output)

    assert output.read_text(encoding="utf-8") == (
        "1\n00:00:00,000 --> 00:00:04,000\nFirst line\n\n"
        "2\n00:00:04,000 --> 00:00:08,000\nSecond line\n\n"
    )


def test_build_final_ffmpeg_command_includes_subtitles_when_enabled(tmp_path):
    silent = tmp_path / "silent.mp4"
    audio = tmp_path / "narration.mp3"
    subtitles = tmp_path / "subtitles.srt"
    output = tmp_path / "final.mp4"

    command = build_final_ffmpeg_command(
        silent,
        audio,
        output,
        captions_enabled=True,
        subtitles_path=subtitles,
        subtitles_available=True,
    )

    assert command[:5] == ["ffmpeg", "-y", "-i", str(silent), "-i"]
    assert str(audio) in command
    assert "-vf" in command
    subtitle_filter = command[command.index("-vf") + 1]
    assert "subtitles='" in subtitle_filter
    assert "force_style='FontName=Arial" in subtitle_filter
    assert command[-1] == str(output)


def test_build_final_ffmpeg_command_skips_subtitles_when_disabled(tmp_path):
    command = build_final_ffmpeg_command(
        tmp_path / "silent.mp4",
        tmp_path / "narration.mp3",
        tmp_path / "final.mp4",
        captions_enabled=False,
        subtitles_path=tmp_path / "subtitles.srt",
        subtitles_available=True,
    )

    assert "-vf" not in command


@pytest.mark.skipif(
    os.getenv("RUN_OFFLINE_VIDEO_TEST", "false").lower() != "true",
    reason="Set RUN_OFFLINE_VIDEO_TEST=true to run the offline MP4 smoke test (needs FFmpeg only, no API keys).",
)
def test_end_to_end_mp4_generation_offline(tmp_path):
    """Produces a real MP4 using pyttsx3 (system TTS) + Pillow + FFmpeg.

    Requires only FFmpeg on PATH; no Google, Gemini, or Pexels keys needed.
    Run with:  $env:RUN_OFFLINE_VIDEO_TEST="true"; pytest .\\tests\\test_video_core.py -k offline
    """
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        pytest.skip("ffmpeg and ffprobe must be available on PATH.")

    from PIL import Image, ImageDraw

    audio = tmp_path / "narration.mp3"
    silent = tmp_path / "silent.mp4"
    subtitles = tmp_path / "subtitles.srt"
    output = tmp_path / "final.mp4"
    text = "Artificial Intelligence is transforming the world. AI helps automate tasks and make smarter decisions."

    create_tts_offline(text, audio, speaking_rate=1.05)

    # Build a minimal 1280x720 explainer card image with Pillow (no Gemini/Pexels needed)
    card = Image.new("RGB", (1280, 720), (13, 24, 48))
    ImageDraw.Draw(card).text((80, 300), "Offline Smoke Test", fill="white")
    card_path = tmp_path / "card.jpg"
    card.save(card_path, quality=92)

    # Animate the card with a slow zoom using FFmpeg
    subprocess.run(
        [
            "ffmpeg", "-y", "-loop", "1", "-i", str(card_path),
            "-vf",
            "scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,"
            "zoompan=z='min(zoom+0.0007,1.07)':d=120:s=1280x720:fps=24,setsar=1,format=yuv420p",
            "-t", "5", "-r", "24", "-an", "-c:v", "libx264",
            "-preset", "veryfast", "-pix_fmt", "yuv420p", str(silent),
        ],
        check=True, capture_output=True, text=True,
    )

    write_srt(["Artificial Intelligence is transforming the world.",
               "AI helps automate tasks and make smarter decisions."], 5.0, subtitles)

    command = build_final_ffmpeg_command(
        silent, audio, output,
        captions_enabled=True, subtitles_path=subtitles, subtitles_available=True,
    )
    subprocess.run(command, check=True, capture_output=True, text=True)

    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
         "-of", "default=noprint_wrappers=1:nokey=1", str(output)],
        check=True, capture_output=True, text=True,
    )

    assert output.exists()
    assert output.stat().st_size > 0
    assert "video" in probe.stdout
    assert "audio" in probe.stdout


@pytest.mark.skipif(
    os.getenv("RUN_REAL_TTS_TEST", "false").lower() != "true",
    reason="Set RUN_REAL_TTS_TEST=true to run the real MP4 generation smoke test.",
)
def test_end_to_end_mp4_generation_with_real_tts(tmp_path):
    if not os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
        pytest.skip("GOOGLE_APPLICATION_CREDENTIALS is required for the real TTS smoke test.")
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        pytest.skip("ffmpeg and ffprobe must be available on PATH.")

    audio = tmp_path / "narration.mp3"
    silent = tmp_path / "silent.mp4"
    subtitles = tmp_path / "subtitles.srt"
    output = tmp_path / "final.mp4"

    create_tts(
        "Artificial intelligence is speaking in a modulated voice.",
        audio,
        "en-IN-Neural2-B",
        speaking_rate=1.1,
        pitch=2.0,
    )
    write_srt(["Artificial intelligence is speaking in a modulated voice."], 2.0, subtitles)

    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=0x102040:s=1280x720:d=2",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            str(silent),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    command = build_final_ffmpeg_command(
        silent,
        audio,
        output,
        captions_enabled=True,
        subtitles_path=subtitles,
        subtitles_available=True,
    )
    subprocess.run(command, check=True, capture_output=True, text=True)

    probe = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert output.exists()
    assert output.stat().st_size > 0
    assert "video" in probe.stdout
    assert "audio" in probe.stdout
