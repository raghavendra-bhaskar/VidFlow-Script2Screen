"""video_core.py — Core audio/video pipeline for VidFlow.

This module is intentionally free of any Streamlit or UI imports so that
every function can be unit-tested in isolation (see tests/test_video_core.py).

Public API
----------
FFMPEG, FFPROBE  : Resolved absolute paths to the FFmpeg binaries.
sentences()      : Split a script string into individual sentence strings.
build_tts_audio_config() : Build a Google Cloud TTS AudioConfig object.
create_tts()     : Synthesise speech with Google Cloud TTS → MP3 file.
create_tts_offline() : Synthesise speech with pyttsx3 (no API key) → MP3 file.
list_offline_voices() : Return available pyttsx3 system voices as (name, id) pairs.
create_tts_edge()    : Synthesise speech with Microsoft Edge neural TTS (edge-tts, free, internet).
list_edge_voices()   : Return curated list of edge-tts neural voice names.
write_srt()      : Write a sentence-timed .srt subtitle file.
build_final_ffmpeg_command() : Assemble the FFmpeg merge + subtitle command.
"""

from pathlib import Path
import re
import shutil
import subprocess
import sys

from google.cloud import texttospeech


def _locate_bin(name):
    """Locate an executable by checking the process PATH first, then the Windows registry PATH.

    Streamlit and other long-running processes may inherit a PATH that predates
    a newly installed tool (e.g. FFmpeg installed via winget mid-session). Reading
    the registry ensures we find the binary even when the process PATH is stale.
    """
    found = shutil.which(name)
    if found:
        return found
    if sys.platform == "win32":
        try:
            import winreg
            dirs = []
            for hive, subkey in [
                (winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
                (winreg.HKEY_CURRENT_USER, r"Environment"),
            ]:
                try:
                    with winreg.OpenKey(hive, subkey) as key:
                        val, _ = winreg.QueryValueEx(key, "Path")
                        dirs.extend(d for d in val.split(";") if d.strip())
                except OSError:
                    pass
            for d in dirs:
                candidate = Path(d.strip()) / (name + ".exe")
                if candidate.is_file():
                    return str(candidate)
        except Exception:
            pass
    return name  # best-effort fallback — let subprocess raise a clear error


FFMPEG = _locate_bin("ffmpeg")
FFPROBE = _locate_bin("ffprobe")


# ASS/SSA subtitle style string passed to the FFmpeg subtitles filter.
# FontSize=22 is legible at 1280x720; MarginV=35 keeps text above the player bar.
SUBTITLE_STYLE = "FontName=Arial,FontSize=22,Outline=2,Shadow=1,Alignment=2,MarginV=35"


def sentences(text):
    """Split a script into a list of individual sentences.

    Uses a lookbehind assertion to split only after sentence-ending punctuation
    (.  !  ?) followed by whitespace, so abbreviations like "AI" are safe.
    Empty strings are filtered out.

    Parameters
    ----------
    text : str
        The full narration script.

    Returns
    -------
    list[str]
        One entry per sentence, stripped of leading/trailing whitespace.
    """
    return [s.strip() for s in re.split(r'(?<=[.!?])\s+', text.strip()) if s.strip()]


def build_tts_audio_config(speaking_rate=1.0, pitch=0.0):
    """Create a Google Cloud TTS AudioConfig for MP3 output.

    Parameters
    ----------
    speaking_rate : float
        Multiplier over normal speed. 1.0 = normal, 1.25 = 25% faster.
        Accepted range: 0.25 – 4.0.
    pitch : float
        Semitone shift relative to the default pitch. 0.0 = no change.
        Accepted range: -20.0 – 20.0.

    Returns
    -------
    texttospeech.AudioConfig
    """
    return texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
        speaking_rate=speaking_rate,
        pitch=pitch,
    )


def create_tts(text, path, voice_name, speaking_rate=1.0, pitch=0.0, tts_client=None):
    """Synthesise speech using Google Cloud Text-to-Speech and write an MP3 file.

    Requires GOOGLE_APPLICATION_CREDENTIALS to be set in the environment.
    Supports Indian English neural and standard voices (en-IN-*).

    Parameters
    ----------
    text : str
        The narration text to synthesise.
    path : pathlib.Path | str
        Destination file path for the MP3 output.
    voice_name : str
        Google Cloud TTS voice name, e.g. "en-IN-Neural2-B".
    speaking_rate : float
        Speed multiplier (default 1.0).
    pitch : float
        Pitch shift in semitones (default 0.0).
    tts_client : texttospeech.TextToSpeechClient | None
        Optional pre-constructed client for testing with a mock/fake.
    """
    client = tts_client or texttospeech.TextToSpeechClient()
    response = client.synthesize_speech(
        input=texttospeech.SynthesisInput(text=text),
        voice=texttospeech.VoiceSelectionParams(language_code="en-IN", name=voice_name),
        audio_config=build_tts_audio_config(speaking_rate=speaking_rate, pitch=pitch),
    )
    Path(path).write_bytes(response.audio_content)


def srt_time(sec):
    """Convert a duration in seconds to SRT timestamp format HH:MM:SS,mmm.

    Parameters
    ----------
    sec : float
        Duration in seconds.

    Returns
    -------
    str
        e.g. '00:01:23,456'
    """
    ms = int(round(sec * 1000))
    hh, rem = divmod(ms, 3600000)
    mm, rem = divmod(rem, 60000)
    ss, ms = divmod(rem, 1000)
    return f"{hh:02}:{mm:02}:{ss:02},{ms:03}"


def write_srt(lines, duration, path):
    """Write sentence-timed subtitle entries to an SRT file.

    Timing is distributed evenly across the total narration duration —
    this is a sentence-level approximation, not word-level alignment.
    Each entry occupies an equal fraction of the total duration.

    Parameters
    ----------
    lines : list[str]
        Individual sentence strings.
    duration : float
        Total narration duration in seconds (from ffprobe).
    path : pathlib.Path | str
        Destination file path for the .srt file.
    """
    per = duration / max(1, len(lines))
    with open(path, "w", encoding="utf-8") as file_obj:
        for index, line in enumerate(lines):
            start = srt_time(index * per)
            end = srt_time(min(duration, (index + 1) * per))
            file_obj.write(f"{index + 1}\n{start} --> {end}\n{line}\n\n")


def escape_subtitle_path(path):
    """Escape a filesystem path for use in an FFmpeg subtitles= filter expression.

    FFmpeg's libass subtitle filter requires the path in POSIX format with the
    Windows drive colon escaped as \\: and any single-quotes escaped as \\'.
    Example: C:\\Users\\foo\\bar.srt → C\\:/Users/foo/bar.srt

    Parameters
    ----------
    path : pathlib.Path | str
        Absolute path to the .srt file.

    Returns
    -------
    str
        Escaped path string safe for embedding in an FFmpeg filter graph.
    """
    escaped = Path(path).as_posix().replace(":", r"\:")
    return escaped.replace("'", r"\'")


def list_offline_voices():
    """Return available pyttsx3 system voices as a list of (display_name, voice_id) tuples.

    Falls back to [("Default", None)] if pyttsx3 is not installed or has no voices.
    """
    try:
        import pyttsx3
        engine = pyttsx3.init()
        voices = engine.getProperty("voices") or []
        result = [(v.name, v.id) for v in voices]
        engine.stop()
        return result if result else [("Default", None)]
    except Exception:
        return [("Default", None)]


def create_tts_offline(text, path, speaking_rate=1.0, voice_id=None):
    """Generate TTS narration using the local system speech engine (pyttsx3).

    No API key or internet connection is needed.
    speaking_rate is a multiplier over the engine default (~200 wpm on Windows SAPI5).
    voice_id selects the system voice; pass None to use the engine default.
    Pitch modulation is not available in offline mode; use Google Cloud TTS for that.
    The output file is MP3 so the rest of the pipeline is unchanged.
    """
    import pyttsx3

    engine = pyttsx3.init()
    # Scale words-per-minute by the requested rate multiplier
    engine.setProperty("rate", int(200 * speaking_rate))
    # Apply the selected system voice if one was chosen
    if voice_id:
        engine.setProperty("voice", voice_id)

    tmp_wav = Path(path).with_suffix(".wav")
    engine.save_to_file(text, str(tmp_wav))
    engine.runAndWait()

    # Convert WAV → MP3 with FFmpeg so the audio format is consistent with the cloud TTS path
    subprocess.run(
        [FFMPEG, "-y", "-i", str(tmp_wav), "-c:a", "libmp3lame", "-b:a", "160k", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    tmp_wav.unlink(missing_ok=True)


# Curated selection of high-quality Microsoft Edge neural voices.
# Keys are human-readable display names shown in the sidebar dropdown.
# Values are the edge-tts voice identifiers passed to edge_tts.Communicate().
EDGE_TTS_VOICES = {
    "Jenny (US, female)": "en-US-JennyNeural",
    "Guy (US, male)": "en-US-GuyNeural",
    "Aria (US, female)": "en-US-AriaNeural",
    "Davis (US, male)": "en-US-DavisNeural",
    "Neerja (India, female)": "en-IN-NeerjaNeural",
    "Prabhat (India, male)": "en-IN-PrabhatNeural",
    "Sonia (UK, female)": "en-GB-SoniaNeural",
    "Ryan (UK, male)": "en-GB-RyanNeural",
    "Natasha (AU, female)": "en-AU-NatashaNeural",
    "William (AU, male)": "en-AU-WilliamNeural",
}


def list_edge_voices():
    """Return the curated edge-tts voice list as (display_name, voice_id) tuples.

    Does NOT require edge-tts to be imported — returns the static list directly.
    """
    return list(EDGE_TTS_VOICES.items())


def create_tts_edge(text, path, voice="en-US-JennyNeural", speaking_rate=1.0):
    """Synthesise speech using Microsoft Edge's online neural TTS (edge-tts package).

    Produces natural, human-quality audio comparable to Azure Neural TTS.
    Free to use with no API key; requires an internet connection.

    Parameters
    ----------
    text : str
        The narration text to synthesise.
    path : pathlib.Path | str
        Destination MP3 file path.  edge-tts writes MP3 directly; no conversion needed.
    voice : str
        Edge TTS voice identifier, e.g. "en-US-JennyNeural".  See EDGE_TTS_VOICES.
    speaking_rate : float
        Speed multiplier relative to normal (1.0).  Converts to edge-tts rate strings
        such as "+10%" (faster) or "-10%" (slower).
    """
    import threading
    import edge_tts

    # edge-tts uses percentage strings: +10% = 10% faster, -10% = 10% slower
    pct = int((speaking_rate - 1.0) * 100)
    rate_str = f"+{pct}%" if pct >= 0 else f"{pct}%"

    async def _synthesise():
        communicate = edge_tts.Communicate(text, voice, rate=rate_str)
        await communicate.save(str(path))

    # Run synthesis in a fresh OS thread with its own event loop so we never
    # collide with Streamlit's internal asyncio event loop running in the main thread.
    exc_bucket: list[BaseException] = []

    def _run_loop():
        import asyncio
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(_synthesise())
        except Exception as exc:
            exc_bucket.append(exc)
        finally:
            loop.close()

    worker = threading.Thread(target=_run_loop, daemon=True)
    worker.start()
    worker.join(timeout=120)
    if exc_bucket:
        raise exc_bucket[0]


def build_subtitle_filter(srt_path):
    """Build the FFmpeg -vf subtitles filter string for burning in captions.

    Parameters
    ----------
    srt_path : pathlib.Path | str
        Path to the .srt subtitle file.

    Returns
    -------
    str
        Complete -vf filter value, e.g.
        "subtitles='C\\:/tmp/subtitles.srt':force_style='FontName=Arial,...'"
    """
    return f"subtitles='{escape_subtitle_path(srt_path)}':force_style='{SUBTITLE_STYLE}'"


def build_video_overlay_command(
    base_video_path,
    overlay_video_path,
    output_path,
    size=0.25,
    position="bottom-right",
    audio_source="base",
):
    """Build an FFmpeg command that places one video over another as picture-in-picture."""
    if not 0.1 <= size <= 0.5:
        raise ValueError("Overlay size must be between 0.1 and 0.5.")

    positions = {
        "top-left": "24:24",
        "top-right": "main_w-overlay_w-24:24",
        "bottom-left": "24:main_h-overlay_h-24",
        "bottom-right": "main_w-overlay_w-24:main_h-overlay_h-24",
    }
    if position not in positions:
        raise ValueError(f"Unsupported overlay position: {position}")
    if audio_source not in {"base", "overlay", "none"}:
        raise ValueError(f"Unsupported audio source: {audio_source}")

    filter_graph = (
        f"[1:v][0:v]scale2ref=w=trunc(main_w*{size}/2)*2:h=-2[pip][base];"
        f"[base][pip]overlay={positions[position]}:eof_action=pass[vout]"
    )
    command = [
        FFMPEG, "-y", "-i", str(base_video_path), "-i", str(overlay_video_path),
        "-filter_complex", filter_graph,
        "-map", "[vout]",
    ]
    if audio_source == "none":
        command.append("-an")
    else:
        command += ["-map", f"{0 if audio_source == 'base' else 1}:a?"]
        command += ["-c:a", "aac", "-b:a", "160k"]
    command += [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output_path),
    ]
    return command


def build_audio_sync_command(
    video_path,
    audio_path,
    output_path,
    video_duration,
    audio_duration,
    audio_offset=0.0,
    mode="replace",
    source_has_audio=True,
    video_speed=1.0,
    trim_start=0.0,
    trim_end=None,
):
    """Build the shared A/V sync command used by standalone sync and voice dubbing."""
    if audio_offset < 0:
        raise ValueError("Audio offset cannot be negative.")
    if mode not in {"replace", "mix"}:
        raise ValueError(f"Unsupported audio sync mode: {mode}")
    if not 0.5 <= video_speed <= 2.0:
        raise ValueError("Video speed must be between 0.5 and 2.0.")
    if trim_start < 0 or (trim_end is not None and not trim_start < trim_end <= video_duration):
        raise ValueError("Video keep-range must be within the source duration.")

    selected_duration = (trim_end if trim_end is not None else video_duration) - trim_start
    output_video_duration = selected_duration / video_speed
    final_duration = max(output_video_duration, audio_offset + audio_duration)
    delay_ms = int(audio_offset * 1000)
    video_filter = (
        f"[0:v]trim=start={trim_start:.3f}:duration={selected_duration:.3f},"
        f"setpts=(PTS-STARTPTS)/{video_speed:.3f}"
    )
    if mode == "mix" and source_has_audio:
        audio_filter = (
            f"[1:a]adelay={delay_ms}|{delay_ms}[voice];"
            f"[0:a]atrim=start={trim_start:.3f}:duration={selected_duration:.3f},"
            f"asetpts=PTS-STARTPTS,atempo={video_speed:.3f}[original];"
            "[original][voice]amix=inputs=2:normalize=0:duration=longest,"
            f"apad=whole_dur={final_duration:.3f}[aout]"
        )
    else:
        audio_filter = (
            f"[1:a]adelay={delay_ms}|{delay_ms},"
            f"apad=whole_dur={final_duration:.3f}[aout]"
        )

    if final_duration > output_video_duration + 0.25:
        extra_duration = final_duration - output_video_duration + 0.1
        video_filter += f",tpad=stop_mode=clone:stop_duration={extra_duration:.3f}"
    video_filter += "[vout]"
    command = [
        FFMPEG, "-y", "-i", str(video_path), "-i", str(audio_path),
        "-filter_complex", f"{video_filter};{audio_filter}",
        "-map", "[vout]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
    ]
    command += [
        "-map", "[aout]", "-c:a", "aac", "-b:a", "160k",
        "-movflags", "+faststart", str(output_path),
    ]
    return command


def build_final_ffmpeg_command(
    silent_video_path,
    audio_path,
    output_path,
    captions_enabled=False,
    subtitles_path=None,
    subtitles_available=True,
):
    """Build the FFmpeg command that merges silent video + narration audio → final MP4.

    The command:
    - Takes stream 0 (video) from silent_video_path
    - Takes stream 0 (audio) from audio_path
    - Optionally burns in subtitles via the libass subtitles filter
    - Re-encodes video with libx264 (CRF 22, veryfast preset)
    - Encodes audio as AAC 160 kbps
    - Uses -shortest to trim at the shorter of video/audio
    - Adds +faststart for browser-friendly streaming

    Parameters
    ----------
    silent_video_path : pathlib.Path | str
        Concatenated video file with no audio track.
    audio_path : pathlib.Path | str
        TTS narration MP3 file.
    output_path : pathlib.Path | str
        Destination for the final MP4.
    captions_enabled : bool
        Whether to burn subtitles into the video (default False).
    subtitles_path : pathlib.Path | str | None
        Path to the .srt file. Only used if captions_enabled is True.
    subtitles_available : bool
        Set to False via env var FFMPEG_SUBTITLES_AVAILABLE=false to disable
        subtitle burning without changing captions_enabled (useful for debugging).

    Returns
    -------
    list[str]
        A command list ready to pass to subprocess.run().
    """
    command = [FFMPEG, "-y", "-i", str(silent_video_path), "-i", str(audio_path)]
    if captions_enabled and subtitles_path and subtitles_available:
        command += ["-vf", build_subtitle_filter(subtitles_path)]
    command += [
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "22",
        "-c:a", "aac",
        "-b:a", "160k",
        "-shortest",
        "-movflags", "+faststart",
        str(output_path),
    ]
    return command
