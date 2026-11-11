"""Hosted face lip-sync for short, consented video and audio clips."""

import os
import subprocess
from urllib.parse import urlparse


KLING_LIPSYNC_ENDPOINT = "fal-ai/kling-video/lipsync/audio-to-video"


def prepare_lipsync_video(video_path, output_path, ffmpeg="ffmpeg"):
    """Convert browser-recorded WebM to the provider's 720p MP4 input format."""
    if video_path.suffix.lower() != ".webm":
        return video_path
    if video_path.stat().st_size > 100_000_000:
        raise ValueError("Lip sync video uploads must be under 100 MB.")
    result = subprocess.run(
        [
            ffmpeg, "-y", "-i", str(video_path), "-map", "0:v:0", "-an",
            "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,"
            "pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output_path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise ValueError(f"Could not convert the WebM video for lip sync: {result.stderr[-1500:]}")
    if not output_path.is_file() or output_path.stat().st_size == 0:
        raise ValueError("WebM conversion did not produce a playable MP4.")
    if output_path.stat().st_size > 100_000_000:
        raise ValueError("Converted lip sync video exceeds the 100 MB provider limit.")
    return output_path


def run_kling_lipsync(video_path, audio_path, video_duration, audio_duration, dimensions):
    if not os.getenv("FAL_KEY"):
        raise ValueError("Set FAL_KEY on the VidFlow server to enable lip sync.")
    if video_path.suffix.lower() not in {".mp4", ".mov"} or video_path.stat().st_size > 100_000_000:
        raise ValueError("Lip sync requires an MP4/MOV video under 100 MB.")
    if audio_path.suffix.lower() not in {".mp3", ".wav", ".ogg", ".m4a", ".aac"} or audio_path.stat().st_size > 5_000_000:
        raise ValueError("Lip sync requires MP3/WAV/OGG/M4A/AAC audio under 5 MB.")
    if not 2 <= video_duration <= 10 or not 2 <= audio_duration <= 60:
        raise ValueError("Lip sync requires 2-10s video and 2-60s audio.")
    if sorted(dimensions) not in ([720, 1280], [1080, 1920]):
        raise ValueError("Lip sync requires a 720p or 1080p video. Resize the video first.")

    import fal_client

    result = fal_client.subscribe(
        KLING_LIPSYNC_ENDPOINT,
        arguments={
            "video_url": fal_client.upload_file(video_path),
            "audio_url": fal_client.upload_file(audio_path),
        },
        client_timeout=1800,
    )
    output_url = result.get("video", {}).get("url", "")
    parsed = urlparse(output_url)
    if parsed.scheme != "https" or parsed.hostname not in {
        "fal.media", "v3.fal.media", "storage.googleapis.com"
    } or (parsed.hostname == "storage.googleapis.com" and not parsed.path.startswith("/falserverless/")):
        raise ValueError("Lip sync provider returned an unexpected video URL.")
    return output_url