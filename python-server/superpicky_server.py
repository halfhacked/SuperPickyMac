#!/usr/bin/env python3
"""SuperPicky Inference Server — pure model inference only."""
import argparse
import os
from typing import Any, Tuple

from flask import Flask, jsonify, request
from flask.wrappers import Response
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

_models: dict = {}
MODELS_DIR = os.environ.get("MODELS_DIR", os.path.expanduser("~/projects/SuperPicky/models"))


def _error(message: str, status: int) -> Tuple[Response, int]:
    """Uniform JSON error response."""
    return jsonify({"error": message}), status


def _require_image() -> Any:
    """Pull the 'image' file from the request, or None if missing."""
    return request.files.get("image")


def get_detector():
    if "detector" not in _models:
        from inference.detector import BirdDetector
        _models["detector"] = BirdDetector(os.path.join(MODELS_DIR, "yolo11l-seg.pt"))
    return _models["detector"]


def get_aesthetics():
    if "aesthetics" not in _models:
        from inference.aesthetics import AestheticsScorer
        _models["aesthetics"] = AestheticsScorer(os.path.join(MODELS_DIR, "cfanet_iaa_ava_res50-3cd62bb3.pth"))
    return _models["aesthetics"]


def get_keypoints():
    if "keypoints" not in _models:
        from inference.keypoints import KeypointPredictor
        _models["keypoints"] = KeypointPredictor(os.path.join(MODELS_DIR, "cub200_keypoint_resnet50_slim.pth"))
    return _models["keypoints"]


def get_flight():
    if "flight" not in _models:
        from inference.flight import FlightPredictor
        _models["flight"] = FlightPredictor(os.path.join(MODELS_DIR, "superFlier_efficientnet.pth"))
    return _models["flight"]


def get_species():
    if "species" not in _models:
        from inference.species import SpeciesClassifier
        _models["species"] = SpeciesClassifier(os.path.join(MODELS_DIR, "model20240824.pth"))
    return _models["species"]


@app.errorhandler(Exception)
def _handle_unexpected(exc: Exception) -> Tuple[Response, int]:
    # Flask's own HTTP errors carry their own status codes; pass those through.
    code = getattr(exc, "code", None)
    if isinstance(code, int):
        return _error(str(exc), code)
    app.logger.exception("Inference endpoint failed")
    return _error(f"{type(exc).__name__}: {exc}", 500)


@app.route("/health", methods=["GET"])
def health() -> Response:
    from inference.device import get_best_device
    return jsonify({
        "status": "ready",
        "models_loaded": list(_models.keys()),
        "device": get_best_device(),
        "version": "1.0.0",
    })


@app.route("/detect", methods=["POST"])
def detect():
    f = _require_image()
    if not f:
        return _error("No image provided", 400)
    return jsonify(get_detector().predict(f.read()))


@app.route("/aesthetics", methods=["POST"])
def aesthetics():
    f = _require_image()
    if not f:
        return _error("No image provided", 400)
    return jsonify(get_aesthetics().predict(f.read()))


@app.route("/keypoints", methods=["POST"])
def keypoints():
    f = _require_image()
    if not f:
        return _error("No image provided", 400)
    return jsonify(get_keypoints().predict(f.read()))


@app.route("/flight", methods=["POST"])
def flight():
    f = _require_image()
    if not f:
        return _error("No image provided", 400)
    return jsonify(get_flight().predict(f.read()))


@app.route("/identify", methods=["POST"])
def identify():
    top_k = request.args.get("top_k", 5, type=int)

    # Prefer file_path (preen handles loading, GPS, everything)
    file_path = request.form.get("file_path") or request.args.get("file_path")
    if file_path:
        return jsonify(get_species().predict_file(file_path, top_k=top_k))

    # Fallback: image bytes (for tests / backward compat)
    f = _require_image()
    if not f:
        return _error("No image or file_path provided", 400)
    temperature = request.args.get("temperature", 0.9, type=float)
    lat = request.args.get("lat", None, type=float)
    lon = request.args.get("lon", None, type=float)
    return jsonify(get_species().predict(
        f.read(), top_k=top_k, temperature=temperature, lat=lat, lon=lon,
    ))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8420)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    app.run(host=args.host, port=args.port, debug=False, threaded=True)
