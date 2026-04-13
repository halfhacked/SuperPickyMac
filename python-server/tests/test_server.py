"""L1 tests — mocked models, no real inference."""
import pytest
from unittest.mock import patch, MagicMock
from io import BytesIO


@pytest.fixture
def client():
    with patch("superpicky_server.get_detector") as mock_det, \
         patch("superpicky_server.get_aesthetics") as mock_aes, \
         patch("superpicky_server.get_keypoints") as mock_kp, \
         patch("superpicky_server.get_flight") as mock_fl, \
         patch("superpicky_server.get_species") as mock_sp:

        mock_det.return_value = MagicMock()
        mock_det.return_value.detect.return_value = {
            "birds": [{"bbox": [0.1, 0.2, 0.6, 0.8], "confidence": 0.94, "mask": "AQID"}]
        }

        mock_aes.return_value = MagicMock()
        mock_aes.return_value.score.return_value = {"score": 6.23, "distribution": []}

        mock_kp.return_value = MagicMock()
        mock_kp.return_value.predict.return_value = {
            "keypoints": {
                "left_eye": {"x": 0.4, "y": 0.3, "visibility": 0.9},
                "right_eye": {"x": 0.6, "y": 0.3, "visibility": 0.9},
                "beak": {"x": 0.5, "y": 0.5, "visibility": 0.95},
            }
        }

        mock_fl.return_value = MagicMock()
        mock_fl.return_value.predict.return_value = {"is_flying": True, "confidence": 0.83}

        mock_sp.return_value = MagicMock()
        mock_sp.return_value.predict.return_value = {
            "species": [{
                "name": "Alcedo atthis",
                "common_name": "Common Kingfisher",
                "confidence": 0.94,
                "cn_name": "\u666e\u901a\u7fe0\u9e1f",
                "pinyin": "p\u01d4 t\u014dng cu\xec ni\u01ceo",
                "threshold_used": "gps",
            }]
        }

        from superpicky_server import app
        app.config["TESTING"] = True
        with app.test_client() as c:
            yield c


def _post_image(client, endpoint):
    data = {"image": (BytesIO(b"\xff\xd8\xff\xe0fake"), "test.jpg")}
    return client.post(endpoint, data=data, content_type="multipart/form-data")


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] == "ready"


def test_detect(client):
    resp = _post_image(client, "/detect")
    assert resp.status_code == 200
    data = resp.get_json()
    assert len(data["birds"]) == 1
    assert data["birds"][0]["confidence"] == 0.94


def test_aesthetics(client):
    resp = _post_image(client, "/aesthetics")
    assert resp.status_code == 200
    assert resp.get_json()["score"] == 6.23


def test_keypoints(client):
    resp = _post_image(client, "/keypoints")
    assert resp.status_code == 200
    assert "keypoints" in resp.get_json()


def test_flight(client):
    resp = _post_image(client, "/flight")
    assert resp.status_code == 200
    assert resp.get_json()["is_flying"] is True


def test_identify(client):
    resp = _post_image(client, "/identify?top_k=3")
    assert resp.status_code == 200
    data = resp.get_json()
    assert len(data["species"]) == 1
    sp = data["species"][0]
    assert "cn_name" in sp
    assert "pinyin" in sp
    assert "threshold_used" in sp


def test_identify_with_gps(client):
    resp = _post_image(client, "/identify?top_k=3&lat=39.9&lon=116.4")
    assert resp.status_code == 200
    data = resp.get_json()
    assert len(data["species"]) == 1
    sp = data["species"][0]
    assert sp["cn_name"] == "\u666e\u901a\u7fe0\u9e1f"
    assert sp["pinyin"] == "p\u01d4 t\u014dng cu\xec ni\u01ceo"
    assert sp["threshold_used"] == "gps"


def test_identify_without_gps(client):
    resp = _post_image(client, "/identify?top_k=5")
    assert resp.status_code == 200
    data = resp.get_json()
    assert len(data["species"]) == 1
    sp = data["species"][0]
    assert "cn_name" in sp
    assert "pinyin" in sp
    assert "threshold_used" in sp


def test_no_image(client):
    resp = client.post("/detect")
    assert resp.status_code == 400
