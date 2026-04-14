"""Shared helpers for inference modules."""
import os
import tempfile
from contextlib import contextmanager
from io import BytesIO
from typing import Iterator

from PIL import Image


def load_pil_image(image_bytes: bytes) -> Image.Image:
    """Decode raw bytes into an RGB PIL image."""
    return Image.open(BytesIO(image_bytes)).convert("RGB")


@contextmanager
def temp_image_file(image_bytes: bytes, suffix: str = ".jpg") -> Iterator[str]:
    """Write bytes to a temp file, yield the path, and clean up on exit."""
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        f.write(image_bytes)
        tmp_path = f.name
    try:
        yield tmp_path
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
