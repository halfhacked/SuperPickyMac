"""L2 E2E integration tests — run against a real inference server with real models.

Validates the contract between Swift client and Python server.
Each test verifies response schema AND reasonable value ranges.

Run: INFERENCE_URL=http://localhost:8420 pytest tests/test_integration.py -v
Or:  scripts/run-l2.sh (starts server on :18420, runs tests, tears down)
"""
import os
import requests
import pytest

BASE_URL = os.environ.get("INFERENCE_URL", "http://localhost:8420")

# Use real bird photo from test-photos folder
TEST_PHOTOS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "test-photos")
BIRD_IMAGE = os.path.join(TEST_PHOTOS_DIR, "kingfisher_darwin.jpg")
# Fallback to fixtures dir
FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
FIXTURE_IMAGE = os.path.join(FIXTURE_DIR, "test_bird.jpg")


def get_test_image():
    """Return path to a real bird photo for testing."""
    if os.path.exists(BIRD_IMAGE):
        return BIRD_IMAGE
    if os.path.exists(FIXTURE_IMAGE):
        return FIXTURE_IMAGE
    pytest.skip("No test bird image available")


@pytest.fixture(autouse=True)
def require_server():
    """Skip all tests if server is not running."""
    try:
        resp = requests.get(f"{BASE_URL}/health", timeout=5)
        if resp.status_code != 200:
            pytest.skip("Inference server not ready")
    except requests.ConnectionError:
        pytest.skip("Inference server not running")


def _post_image(endpoint, image_path=None):
    path = image_path or get_test_image()
    with open(path, "rb") as f:
        return requests.post(
            f"{BASE_URL}/{endpoint}",
            files={"image": (os.path.basename(path), f, "image/jpeg")},
            timeout=120,
        )


# ── Health ──────────────────────────────────────────────

class TestHealth:
    def test_returns_ready_status(self):
        resp = requests.get(f"{BASE_URL}/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ready"

    def test_returns_device_info(self):
        data = requests.get(f"{BASE_URL}/health").json()
        assert "device" in data
        assert data["device"] in ("mps", "cuda", "cpu")

    def test_returns_version(self):
        data = requests.get(f"{BASE_URL}/health").json()
        assert "version" in data
        assert isinstance(data["version"], str)


# ── Detection ───────────────────────────────────────────

class TestDetect:
    def test_returns_birds_array(self):
        resp = _post_image("detect")
        assert resp.status_code == 200
        data = resp.json()
        assert "birds" in data
        assert isinstance(data["birds"], list)

    def test_detects_bird_in_photo(self):
        """Real bird photo should detect at least one bird."""
        data = _post_image("detect").json()
        assert len(data["birds"]) >= 1, "Should detect at least one bird"

    def test_bbox_format(self):
        """Bbox should be [x1, y1, x2, y2] normalized 0-1."""
        data = _post_image("detect").json()
        bird = data["birds"][0]
        assert "bbox" in bird
        bbox = bird["bbox"]
        assert len(bbox) == 4
        for val in bbox:
            assert 0.0 <= val <= 1.0, f"Bbox value {val} not in [0,1]"
        assert bbox[2] > bbox[0], "x2 should be > x1"
        assert bbox[3] > bbox[1], "y2 should be > y1"

    def test_confidence_range(self):
        """Confidence should be 0-1."""
        bird = _post_image("detect").json()["birds"][0]
        assert "confidence" in bird
        assert 0.0 <= bird["confidence"] <= 1.0

    def test_confidence_reasonable(self):
        """Real bird photo should have high confidence."""
        bird = _post_image("detect").json()["birds"][0]
        assert bird["confidence"] > 0.5, "Real bird should have >50% confidence"

    def test_mask_present(self):
        """Should return a base64-encoded mask."""
        bird = _post_image("detect").json()["birds"][0]
        assert "mask" in bird
        assert isinstance(bird["mask"], str)
        assert len(bird["mask"]) > 0, "Mask should not be empty"

    def test_no_image_returns_400(self):
        resp = requests.post(f"{BASE_URL}/detect", timeout=10)
        assert resp.status_code == 400
        assert "error" in resp.json()


# ── Aesthetics ──────────────────────────────────────────

class TestAesthetics:
    def test_returns_score(self):
        resp = _post_image("aesthetics")
        assert resp.status_code == 200
        data = resp.json()
        assert "score" in data
        assert isinstance(data["score"], (int, float))

    def test_score_in_valid_range(self):
        """TOPIQ score should be in 1-10 range."""
        score = _post_image("aesthetics").json()["score"]
        assert 1.0 <= score <= 10.0, f"Score {score} not in [1,10]"

    def test_no_image_returns_400(self):
        resp = requests.post(f"{BASE_URL}/aesthetics", timeout=10)
        assert resp.status_code == 400


# ── Keypoints ───────────────────────────────────────────

class TestKeypoints:
    def test_returns_keypoints_dict(self):
        resp = _post_image("keypoints")
        assert resp.status_code == 200
        data = resp.json()
        assert "keypoints" in data

    def test_has_all_three_keypoints(self):
        kp = _post_image("keypoints").json()["keypoints"]
        for part in ["left_eye", "right_eye", "beak"]:
            assert part in kp, f"Missing keypoint: {part}"

    def test_keypoint_fields(self):
        kp = _post_image("keypoints").json()["keypoints"]
        for part in ["left_eye", "right_eye", "beak"]:
            assert "x" in kp[part]
            assert "y" in kp[part]
            assert "visibility" in kp[part]

    def test_coordinates_normalized(self):
        """Keypoint coords should be normalized 0-1."""
        kp = _post_image("keypoints").json()["keypoints"]
        for part in ["left_eye", "right_eye", "beak"]:
            assert 0.0 <= kp[part]["x"] <= 1.0, f"{part}.x out of range"
            assert 0.0 <= kp[part]["y"] <= 1.0, f"{part}.y out of range"

    def test_visibility_range(self):
        kp = _post_image("keypoints").json()["keypoints"]
        for part in ["left_eye", "right_eye", "beak"]:
            assert 0.0 <= kp[part]["visibility"] <= 1.0

    def test_no_image_returns_400(self):
        resp = requests.post(f"{BASE_URL}/keypoints", timeout=10)
        assert resp.status_code == 400


# ── Flight ──────────────────────────────────────────────

class TestFlight:
    def test_returns_is_flying(self):
        resp = _post_image("flight")
        assert resp.status_code == 200
        data = resp.json()
        assert "is_flying" in data
        assert isinstance(data["is_flying"], bool)

    def test_returns_confidence(self):
        data = _post_image("flight").json()
        assert "confidence" in data
        assert 0.0 <= data["confidence"] <= 1.0

    def test_no_image_returns_400(self):
        resp = requests.post(f"{BASE_URL}/flight", timeout=10)
        assert resp.status_code == 400


# ── Identify ────────────────────────────────────────────

class TestIdentify:
    def test_returns_species_list(self):
        resp = _post_image("identify?top_k=5")
        assert resp.status_code == 200
        data = resp.json()
        assert "species" in data
        assert isinstance(data["species"], list)

    def test_species_has_name_and_confidence(self):
        species = _post_image("identify?top_k=3").json()["species"]
        if len(species) > 0:
            sp = species[0]
            assert "name" in sp
            assert "confidence" in sp
            assert isinstance(sp["name"], str)
            assert len(sp["name"]) > 0

    def test_confidence_normalized(self):
        """Confidence should be 0-1 (not 0-100)."""
        species = _post_image("identify?top_k=3").json()["species"]
        for sp in species:
            assert 0.0 <= sp["confidence"] <= 1.0, f"Confidence {sp['confidence']} not in [0,1]"

    def test_top_k_limits_results(self):
        species3 = _post_image("identify?top_k=3").json()["species"]
        assert len(species3) <= 3

    def test_no_image_returns_400(self):
        resp = requests.post(f"{BASE_URL}/identify", timeout=10)
        assert resp.status_code == 400


# ── Cross-endpoint pipeline ─────────────────────────────

class TestPipeline:
    """Test the full pipeline as the Swift app would call it."""

    def test_detect_then_crop_then_identify(self):
        """Simulates: detect bird → crop → identify species."""
        # Step 1: Detect
        detect_data = _post_image("detect").json()
        assert len(detect_data["birds"]) >= 1

        # Step 2: The Swift app would crop here.
        # We send the same full image to identify (server-side doesn't require crop)
        identify_data = _post_image("identify?top_k=5").json()
        assert "species" in identify_data

    def test_all_endpoints_accept_same_image(self):
        """All 5 endpoints should handle the same image without error."""
        for endpoint in ["detect", "aesthetics", "keypoints", "flight", "identify"]:
            resp = _post_image(endpoint)
            assert resp.status_code == 200, f"{endpoint} failed with {resp.status_code}"
