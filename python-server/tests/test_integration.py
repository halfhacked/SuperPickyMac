"""L2 Integration tests — run against a real Python server.

These require real models loaded. Run via scripts/run-l2.sh.
"""
import os
import requests
import pytest

BASE_URL = os.environ.get("INFERENCE_URL", "http://localhost:18420")
FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
TEST_IMAGE = os.path.join(FIXTURE_DIR, "test_bird.jpg")


@pytest.fixture(autouse=True)
def require_server():
    try:
        resp = requests.get(f"{BASE_URL}/health", timeout=5)
        if resp.status_code != 200:
            pytest.skip("Inference server not ready")
    except requests.ConnectionError:
        pytest.skip("Inference server not running")


def _post_image(endpoint):
    with open(TEST_IMAGE, "rb") as f:
        return requests.post(
            f"{BASE_URL}/{endpoint}",
            files={"image": ("test_bird.jpg", f, "image/jpeg")},
            timeout=120,
        )


def test_health():
    resp = requests.get(f"{BASE_URL}/health")
    data = resp.json()
    assert data["status"] == "ready"
    assert "device" in data


def test_detect_returns_birds():
    resp = _post_image("detect")
    assert resp.status_code == 200
    data = resp.json()
    assert "birds" in data
    assert isinstance(data["birds"], list)


def test_aesthetics_returns_score():
    resp = _post_image("aesthetics")
    assert resp.status_code == 200
    data = resp.json()
    assert "score" in data
    assert isinstance(data["score"], (int, float))


def test_keypoints_returns_coords():
    resp = _post_image("keypoints")
    assert resp.status_code == 200
    data = resp.json()
    assert "keypoints" in data


def test_flight_returns_bool():
    resp = _post_image("flight")
    assert resp.status_code == 200
    data = resp.json()
    assert "is_flying" in data
    assert isinstance(data["is_flying"], bool)


def test_identify_returns_species():
    resp = _post_image("identify?top_k=3")
    assert resp.status_code == 200
    data = resp.json()
    assert "species" in data


def test_no_image_returns_400():
    resp = requests.post(f"{BASE_URL}/detect", timeout=10)
    assert resp.status_code == 400
