from pathlib import Path
from types import SimpleNamespace
import os
import shutil
import subprocess

import pytest
from video_core import (
    FFMPEG,
    FFPROBE,
    build_audio_sync_command,
    build_final_ffmpeg_command,
    build_video_overlay_command,
    build_tts_audio_config,
    create_tts,
    create_tts_offline,
    sentences,
    write_srt,
)
from ollama_client import get_ollama_api_url, get_ollama_base_url, narrate_frames, storyboard_scene_text
from media_import import (
    browser_video_preview_url,
    download_authorized_youtube_video,
    google_drive_confirmation_url,
    normalize_google_drive_url,
)
from lipsync_client import KLING_LIPSYNC_ENDPOINT, prepare_lipsync_video, run_kling_lipsync


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


def test_ollama_narration_sends_one_image_per_request(monkeypatch):
    import json
    import ollama_client

    requests = []

    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def read(self):
            return b'{"message":{"content":"Scene description"}}'

    def fake_urlopen(request, timeout):
        requests.append(json.loads(request.data))
        return Response()

    monkeypatch.setattr(ollama_client, "urlopen", fake_urlopen)
    assert narrate_frames("llava:7b", [b"first", b"second"], "Write a script") == "Scene description"
    assert len(requests) == 3
    assert all(len(request["messages"][0]["images"]) == 1 for request in requests[:2])
    assert "images" not in requests[2]["messages"][0]
    assert "Frame 2: Scene description" in requests[2]["messages"][0]["content"]


def test_ollama_narration_reports_api_error(monkeypatch):
    import io
    from urllib.error import HTTPError
    import ollama_client

    def fake_urlopen(request, timeout):
        raise HTTPError(request.full_url, 400, "Bad Request", {}, io.BytesIO(b'{"error":"image too large"}'))

    monkeypatch.setattr(ollama_client, "urlopen", fake_urlopen)
    with pytest.raises(ValueError, match="Ollama HTTP 400: image too large"):
        narrate_frames("llava:7b", [b"image"], "Write a script")


def test_storyboard_scene_text_uses_ollama_chat(monkeypatch):
    import ollama_client

    monkeypatch.setattr(ollama_client, "_chat", lambda model, content, image=None: "Soft sunrise over a city skyline")
    assert storyboard_scene_text("llama3.2", "AI improves productivity") == "Soft sunrise over a city skyline"


def test_youtube_import_only_downloads_canonical_single_video(monkeypatch, tmp_path):
    import yt_dlp

    class FakeYoutubeDL:
        def __init__(self, options):
            self.options = options

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def download(self, urls):
            assert urls == ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"]
            assert self.options["noplaylist"] is True
            Path(self.options["outtmpl"].replace("%(ext)s", "mp4")).write_bytes(b"video")

    monkeypatch.setattr(yt_dlp, "YoutubeDL", FakeYoutubeDL)
    destination = tmp_path / "download.mp4"
    assert download_authorized_youtube_video(
        "https://youtu.be/dQw4w9WgXcQ?list=ignored", destination
    ) == destination
    assert destination.read_bytes() == b"video"
    with pytest.raises(ValueError, match="single YouTube video"):
        download_authorized_youtube_video("https://example.com/watch?v=dQw4w9WgXcQ", destination)
    download_authorized_youtube_video("https://m.youtube.com/shorts/dQw4w9WgXcQ", destination)


def test_browser_video_preview_urls():
    assert browser_video_preview_url("https://youtu.be/dQw4w9WgXcQ") == (
        "youtube", "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"
    )
    assert browser_video_preview_url("https://drive.google.com/file/d/abc123/view") == (
        "drive", "https://drive.google.com/file/d/abc123/preview"
    )
    assert browser_video_preview_url("https://media.example.com/video.mp4") == (
        "direct", "https://media.example.com/video.mp4"
    )
    with pytest.raises(ValueError, match="HTTPS"):
        browser_video_preview_url("http://media.example.com/video.mp4")


def test_prepare_lipsync_converts_webm_to_mp4(monkeypatch, tmp_path):
    import lipsync_client

    source = tmp_path / "webcam.webm"
    target = tmp_path / "source.mp4"
    source.write_bytes(b"webm")
    calls = []

    def fake_run(command, capture_output, text):
        calls.append(command)
        target.write_bytes(b"mp4")
        return SimpleNamespace(returncode=0, stderr="")

    monkeypatch.setattr(lipsync_client.subprocess, "run", fake_run)
    assert prepare_lipsync_video(source, target, "ffmpeg") == target
    assert calls[0][0:4] == ["ffmpeg", "-y", "-i", str(source)]
    assert "libx264" in calls[0]
    assert calls[0][-1] == str(target)


def test_kling_lipsync_uploads_approved_inputs_and_validates_result(monkeypatch, tmp_path):
    import fal_client

    monkeypatch.setenv("FAL_KEY", "test-key")
    video_path = tmp_path / "face.mp4"
    audio_path = tmp_path / "speech.mp3"
    video_path.write_bytes(b"video")
    audio_path.write_bytes(b"audio")
    uploads = []

    def fake_upload(path):
        uploads.append(path)
        return f"https://fal.media/{path.name}"

    def fake_subscribe(endpoint, arguments, client_timeout):
        assert endpoint == KLING_LIPSYNC_ENDPOINT
        assert client_timeout == 1800
        assert arguments == {"video_url": "https://fal.media/face.mp4", "audio_url": "https://fal.media/speech.mp3"}
        return {"video": {"url": "https://storage.googleapis.com/falserverless/result.mp4"}}

    monkeypatch.setattr(fal_client, "upload_file", fake_upload)
    monkeypatch.setattr(fal_client, "subscribe", fake_subscribe)
    assert run_kling_lipsync(video_path, audio_path, 4, 4, (1280, 720)).endswith("result.mp4")
    assert uploads == [video_path, audio_path]
    with pytest.raises(ValueError, match="2-10s video"):
        run_kling_lipsync(video_path, audio_path, 11, 4, (1280, 720))


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

    assert command[:5] == [FFMPEG, "-y", "-i", str(silent), "-i"]
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


def test_build_video_overlay_command_places_clip_bottom_right_and_uses_its_audio(tmp_path):
    command = build_video_overlay_command(
        tmp_path / "base.mp4",
        tmp_path / "camera.webm",
        tmp_path / "output.mp4",
        size=0.3,
        audio_source="overlay",
    )

    filter_graph = command[command.index("-filter_complex") + 1]
    assert "scale2ref=w=trunc(main_w*0.3/2)*2:h=-2[pip][base]" in filter_graph
    assert "overlay=main_w-overlay_w-24:main_h-overlay_h-24" in filter_graph
    assert command[command.index("-map") + 1] == "[vout]"
    assert "1:a?" in command
    assert command[-1] == str(tmp_path / "output.mp4")


def test_build_video_overlay_command_rejects_invalid_size(tmp_path):
    with pytest.raises(ValueError, match="Overlay size"):
        build_video_overlay_command(
            tmp_path / "base.mp4", tmp_path / "overlay.mp4", tmp_path / "output.mp4", size=0.8
        )


def test_build_audio_sync_command_maps_recorded_audio_and_applies_offset(tmp_path):
    command = build_audio_sync_command(
        tmp_path / "video.mp4", tmp_path / "voice.webm", tmp_path / "dubbed.mp4",
        video_duration=10, audio_duration=8, audio_offset=0.5,
        mode="replace", source_has_audio=True,
    )

    graph = command[command.index("-filter_complex") + 1]
    assert "[1:a]adelay=500|500" in graph
    assert "[aout]" in command
    assert command[command.index("-map") + 1] == "[vout]"
    assert command[command.index("-map", command.index("-map") + 1) + 1] == "[aout]"


def test_build_audio_sync_command_mixes_original_audio_and_extends_short_video(tmp_path):
    command = build_audio_sync_command(
        tmp_path / "video.mp4", tmp_path / "voice.webm", tmp_path / "dubbed.mp4",
        video_duration=5, audio_duration=7, audio_offset=1,
        mode="mix", source_has_audio=True,
    )

    graph = command[command.index("-filter_complex") + 1]
    assert "amix=inputs=2" in graph
    assert "tpad=stop_mode=clone" in graph
    assert command[command.index("-map") + 1] == "[vout]"
    assert "libx264" in command


def test_audio_sync_command_trims_and_changes_export_speed(tmp_path):
    command = build_audio_sync_command(
        tmp_path / "video.mp4", tmp_path / "voice.webm", tmp_path / "out.mp4",
        video_duration=20, audio_duration=3, video_speed=1.5,
        trim_start=4, trim_end=13, mode="mix",
    )
    graph = command[command.index("-filter_complex") + 1]
    assert "trim=start=4.000:duration=9.000,setpts=(PTS-STARTPTS)/1.500" in graph
    assert "atrim=start=4.000:duration=9.000" in graph
    assert "atempo=1.500" in graph
    assert "tpad=" not in graph


def test_audio_sync_command_rejects_bad_speed_and_keep_range(tmp_path):
    with pytest.raises(ValueError, match="speed"):
        build_audio_sync_command(tmp_path / "v.mp4", tmp_path / "a.mp3", tmp_path / "o.mp4", 10, 5, video_speed=0.1)
    with pytest.raises(ValueError, match="keep-range"):
        build_audio_sync_command(tmp_path / "v.mp4", tmp_path / "a.mp3", tmp_path / "o.mp4", 10, 5, trim_start=8, trim_end=11)


def test_ollama_api_url_uses_configured_server_and_normalizes_slashes(monkeypatch):
    monkeypatch.setenv("OLLAMA_BASE_URL", "http://ollama.internal:11434/")

    assert get_ollama_base_url() == "http://ollama.internal:11434"
    assert get_ollama_api_url("/api/tags") == "http://ollama.internal:11434/api/tags"


def test_ollama_api_url_defaults_to_local_server(monkeypatch):
    monkeypatch.delenv("OLLAMA_BASE_URL", raising=False)

    assert get_ollama_api_url("api/chat") == "http://localhost:11434/api/chat"


def test_google_drive_share_url_becomes_direct_download_and_keeps_resource_key():
    url, is_drive = normalize_google_drive_url(
        "https://drive.google.com/file/d/abc123/view?usp=sharing&resourcekey=key456"
    )

    assert is_drive is True
    assert url == "https://drive.google.com/uc?export=download&id=abc123&resourcekey=key456"


def test_google_drive_confirmation_form_is_followed_safely():
    html = (
        '<form id="download-form" action="https://drive.usercontent.google.com/download">'
        '<input type="hidden" name="id" value="abc123">'
        '<input type="hidden" name="export" value="download">'
        '<input type="hidden" name="confirm" value="token789"></form>'
    )

    assert google_drive_confirmation_url("https://drive.google.com/uc", html) == (
        "https://drive.usercontent.google.com/download?id=abc123&export=download&confirm=token789"
    )


def test_google_drive_confirmation_keeps_action_query_and_id_without_hidden_id():
    html = (
        '<form id="download-form" action="https://drive.usercontent.google.com/download?id=abc123&export=download">'
        '<input type="hidden" name="confirm" value="token789"></form>'
    )

    assert google_drive_confirmation_url("https://drive.google.com/uc", html) == (
        "https://drive.usercontent.google.com/download?id=abc123&export=download&confirm=token789"
    )


def test_google_drive_confirmation_accepts_matching_download_link_only():
    html = (
        '<a href="https://drive.usercontent.google.com/download?id=abc123&amp;confirm=t&amp;export=download">Download anyway</a>'
    )
    assert google_drive_confirmation_url("https://drive.google.com/uc?id=abc123", html) == (
        "https://drive.usercontent.google.com/download?id=abc123&confirm=t&export=download"
    )
    assert google_drive_confirmation_url("https://drive.google.com/uc?id=other", html) is None


def test_google_drive_confirmation_rejects_external_form_action():
    html = (
        '<form action="https://attacker.example/download">'
        '<input name="id" value="abc123"></form>'
    )

    assert google_drive_confirmation_url("https://drive.google.com/uc", html) is None


@pytest.mark.skipif(
    not (shutil.which(FFMPEG) or Path(FFMPEG).is_file()),
    reason="FFmpeg is required for the picture-in-picture smoke test.",
)
def test_video_overlay_command_creates_composited_mp4(tmp_path):
    base = tmp_path / "base.mp4"
    overlay = tmp_path / "overlay.mp4"
    output = tmp_path / "picture_in_picture.mp4"
    for color, size, path in [("blue", "640x360", base), ("red", "1280x720", overlay)]:
        subprocess.run(
            [
                FFMPEG, "-y", "-f", "lavfi", "-i", f"color=c={color}:s={size}:r=24:d=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    subprocess.run(
        build_video_overlay_command(base, overlay, output, size=0.25, audio_source="none"),
        check=True,
        capture_output=True,
        text=True,
    )
    dimensions = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
         "-of", "csv=s=x:p=0", str(output)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    assert dimensions == "640x360"


@pytest.mark.skipif(
    not (shutil.which(FFMPEG) or Path(FFMPEG).is_file()),
    reason="FFmpeg is required for the voice dubbing mux smoke test.",
)
def test_audio_sync_command_creates_mp4_with_audio_and_video(tmp_path):
    video = tmp_path / "source.mp4"
    voice = tmp_path / "voice.webm"
    output = tmp_path / "dubbed.mp4"
    subprocess.run(
        [FFMPEG, "-y", "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=24:d=1",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)],
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        [FFMPEG, "-y", "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
         "-c:a", "libopus", str(voice)],
        check=True, capture_output=True, text=True,
    )

    subprocess.run(
        build_audio_sync_command(video, voice, output, 1, 1, audio_offset=0.1),
        check=True, capture_output=True, text=True,
    )
    streams = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(output)],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()

    assert "video" in streams
    assert "audio" in streams

    sped_output = tmp_path / "sped_dub.mp4"
    subprocess.run(
        build_audio_sync_command(
            video, voice, sped_output, 1, 1, video_speed=1.5,
            trim_start=0.1, trim_end=0.8,
        ),
        check=True, capture_output=True, text=True,
    )
    sped_streams = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(sped_output)],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    assert set(sped_streams) == {"video", "audio"}

    mislabeled_recording = tmp_path / "browser_recording.mp3"
    shutil.copyfile(voice, mislabeled_recording)
    remuxed = tmp_path / "duration_fix.mkv"
    subprocess.run(
        [FFMPEG, "-y", "-i", str(mislabeled_recording), "-c", "copy", str(remuxed)],
        check=True, capture_output=True, text=True,
    )
    duration = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(remuxed)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert float(duration) > 0


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
