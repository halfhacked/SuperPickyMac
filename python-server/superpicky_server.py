#!/usr/bin/env python3
"""SuperPicky Inference Server — pure model inference only."""
import argparse
import os
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

_models = {}
MODELS_DIR = os.environ.get("MODELS_DIR", os.path.expanduser("~/projects/SuperPicky/models"))


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


@app.route("/health", methods=["GET"])
def health():
    from inference.device import get_best_device
    return jsonify({"status": "ready", "models_loaded": list(_models.keys()), "device": get_best_device(), "version": "1.0.0"})


@app.route("/detect", methods=["POST"])
def detect():
    f = request.files.get("image")
    if not f:
        return jsonify({"error": "No image provided"}), 400
    return jsonify(get_detector().detect(f.read()))


@app.route("/aesthetics", methods=["POST"])
def aesthetics():
    f = request.files.get("image")
    if not f:
        return jsonify({"error": "No image provided"}), 400
    return jsonify(get_aesthetics().score(f.read()))


@app.route("/keypoints", methods=["POST"])
def keypoints():
    f = request.files.get("image")
    if not f:
        return jsonify({"error": "No image provided"}), 400
    return jsonify(get_keypoints().predict(f.read()))


@app.route("/flight", methods=["POST"])
def flight():
    f = request.files.get("image")
    if not f:
        return jsonify({"error": "No image provided"}), 400
    return jsonify(get_flight().predict(f.read()))


@app.route("/identify", methods=["POST"])
def identify():
    f = request.files.get("image")
    if not f:
        return jsonify({"error": "No image provided"}), 400
    top_k = request.args.get("top_k", 5, type=int)
    temperature = request.args.get("temperature", 0.9, type=float)
    lat = request.args.get("lat", None, type=float)
    lon = request.args.get("lon", None, type=float)
    return jsonify(get_species().predict(f.read(), top_k=top_k, temperature=temperature, lat=lat, lon=lon))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8420)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    app.run(host=args.host, port=args.port, debug=False, threaded=True)
