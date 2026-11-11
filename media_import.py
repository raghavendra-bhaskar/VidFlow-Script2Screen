"""Helpers for importing publicly shared Google Drive video files."""

import re
from html.parser import HTMLParser
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, urlencode, urljoin, urlparse, urlunparse


_GOOGLE_DRIVE_HOSTS = {"drive.google.com", "www.drive.google.com", "drive.usercontent.google.com"}
_YOUTUBE_HOSTS = {
    "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"
}


def _youtube_video_id(url):
    parsed = urlparse(url.strip())
    if parsed.hostname not in _YOUTUBE_HOSTS:
        return None
    if parsed.hostname == "youtu.be":
        video_id = parsed.path.strip("/").split("/", 1)[0]
    elif parsed.path == "/watch":
        video_id = parse_qs(parsed.query).get("v", [""])[0]
    else:
        parts = parsed.path.strip("/").split("/")
        video_id = parts[1] if len(parts) == 2 and parts[0] in {"shorts", "embed", "live"} else ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise ValueError("Use a single YouTube watch, Shorts, or youtu.be video URL.")
    return video_id


def browser_video_preview_url(url):
    """Return an embeddable browser preview for Drive, YouTube, or direct HTTPS media."""
    parsed = urlparse(url.strip())
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Use a valid HTTPS video URL.")
    if parsed.port not in (None, 443):
        raise ValueError("Video URLs on custom ports are not supported.")

    video_id = _youtube_video_id(url)
    if video_id:
        return "youtube", f"https://www.youtube-nocookie.com/embed/{video_id}"

    if parsed.hostname in _GOOGLE_DRIVE_HOSTS:
        normalized_url, _ = normalize_google_drive_url(url)
        file_id = parse_qs(urlparse(normalized_url).query).get("id", [""])[0]
        if not file_id:
            raise ValueError("This Google Drive URL does not identify a file.")
        resource_key = parse_qs(parsed.query).get("resourcekey", [None])[0]
        query = urlencode({"resourcekey": resource_key}) if resource_key else ""
        suffix = f"?{query}" if query else ""
        return "drive", f"https://drive.google.com/file/d/{file_id}/preview{suffix}"

    return "direct", url


def normalize_google_drive_url(url):
    """Convert common Drive share URLs to the direct-download endpoint."""
    parsed = urlparse(url)
    if parsed.hostname not in _GOOGLE_DRIVE_HOSTS:
        return url, False

    query = parse_qs(parsed.query)
    file_id = query.get("id", [None])[0]
    if not file_id:
        match = re.search(r"/file/d/([^/]+)", parsed.path)
        file_id = match.group(1) if match else None
    if not file_id:
        return url, True

    download_params = {"export": "download", "id": file_id}
    resource_key = query.get("resourcekey", [None])[0]
    if resource_key:
        download_params["resourcekey"] = resource_key
    return f"https://drive.google.com/uc?{urlencode(download_params)}", True


def download_authorized_youtube_video(url, destination, max_bytes=1_000_000_000):
    """Import one authorized YouTube video without accepting arbitrary extractor URLs."""
    parsed = urlparse(url.strip())
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError("Use a public HTTPS YouTube video URL.")
    video_id = _youtube_video_id(url)
    if not video_id:
        raise ValueError("Use a single YouTube video URL, not a playlist or arbitrary site.")

    from yt_dlp import YoutubeDL

    with TemporaryDirectory(prefix="youtube_import_") as temp_dir:
        output_template = str(Path(temp_dir) / "download.%(ext)s")
        with YoutubeDL({
            "outtmpl": output_template,
            "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]",
            "merge_output_format": "mp4",
            "noplaylist": True,
            "max_filesize": max_bytes,
            "quiet": True,
        }) as downloader:
            downloader.download([f"https://www.youtube.com/watch?v={video_id}"])
        outputs = list(Path(temp_dir).glob("download.*"))
        if len(outputs) != 1 or outputs[0].stat().st_size > max_bytes:
            raise ValueError("YouTube import did not produce one video under the size limit.")
        outputs[0].replace(destination)
        return destination


class _DownloadFormParser(HTMLParser):
    """Extract hidden fields from a Google Drive download confirmation form."""

    def __init__(self):
        super().__init__()
        self._in_form = False
        self.action = None
        self.fields = {}
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form":
            action = attrs.get("action", "")
            if "download" in action or attrs.get("id") == "download-form":
                self._in_form = True
                self.action = action
        elif tag == "input" and self._in_form and attrs.get("name"):
            self.fields[attrs["name"]] = attrs.get("value", "")
        elif tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])

    def handle_endtag(self, tag):
        if tag == "form" and self._in_form:
            self._in_form = False


def google_drive_confirmation_url(response_url, html):
    """Return a safe Drive download-form URL, or None when no form is present."""
    parser = _DownloadFormParser()
    parser.feed(html)
    expected_id = parse_qs(urlparse(response_url).query).get("id", [None])[0]
    candidates = ([parser.action] if parser.action else []) + parser.links
    for candidate in candidates:
        action = urlparse(urljoin(response_url, candidate))
        if action.scheme != "https" or action.hostname not in _GOOGLE_DRIVE_HOSTS:
            continue
        if action.path not in {"/download", "/uc"}:
            continue
        fields = parse_qs(action.query, keep_blank_values=True)
        if candidate == parser.action:
            fields.update({key: [value] for key, value in parser.fields.items()})
        if not fields.get("id") or (expected_id and fields["id"][0] != expected_id):
            continue
        if not fields.get("confirm"):
            continue
        return urlunparse(action._replace(query=urlencode(fields, doseq=True), fragment=""))
    return None