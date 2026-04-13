import sys
import os
from PIL import Image
from io import BytesIO
from inference.device import get_best_device
from pypinyin import pinyin, Style

# Load OSEA classifier: prefer preen (has get_logits/predict_from_logits for pre-softmax masking),
# fall back to SuperPicky. We import via importlib to avoid the local birdid package shadowing.
import importlib.util

PREEN_DIR = os.path.expanduser("~/projects/preen/src/preen")
SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))

_osea_module = None
for _base in [PREEN_DIR, SUPERPICKY_DIR]:
    _path = os.path.join(_base, "birdid", "osea_classifier.py")
    if os.path.isfile(_path):
        _spec = importlib.util.spec_from_file_location("_osea_classifier", _path)
        _osea_module = importlib.util.module_from_spec(_spec)
        # Ensure the parent birdid package data is findable
        if _base not in sys.path:
            sys.path.insert(0, _base)
        _spec.loader.exec_module(_osea_module)
        if hasattr(_osea_module, "OSEAClassifier") and hasattr(_osea_module.OSEAClassifier, "get_logits"):
            break
        _osea_module = None

if _osea_module is None:
    raise ImportError("Could not find OSEAClassifier with get_logits in preen or SuperPicky")

# Thresholds: regional filters use 80%, global uses 90%
REGIONAL_THRESHOLD = 0.80
GLOBAL_THRESHOLD = 0.90


def _to_pinyin(cn_name: str) -> str:
    """Convert Chinese name to pinyin string."""
    if not cn_name:
        return ""
    result = pinyin(cn_name, style=Style.TONE, errors="ignore")
    return " ".join([syllable[0] for syllable in result])


class SpeciesClassifier:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        OSEAClassifier = _osea_module.OSEAClassifier
        self.classifier = OSEAClassifier(model_path=model_path, device=self.device)
        self._avonet = None

    def _get_avonet(self):
        if self._avonet is None:
            # Import from local python-server/birdid/ explicitly to avoid preen's version
            _local_avonet_path = os.path.join(os.path.dirname(__file__), "..", "birdid", "avonet_filter.py")
            _spec = importlib.util.spec_from_file_location("_local_avonet", _local_avonet_path)
            _mod = importlib.util.module_from_spec(_spec)
            _spec.loader.exec_module(_mod)
            self._avonet = _mod.AvonetFilter()
        return self._avonet

    def predict(self, image_bytes: bytes, top_k: int = 5,
                temperature: float = 0.9,
                lat: float = None, lon: float = None) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")

        # Get logits once (no re-inference)
        logits = self.classifier.get_logits(image)

        # Build filter chain based on GPS
        avonet = self._get_avonet()
        filter_chain = avonet.get_filter_chain(lat, lon)

        best_result = None
        threshold_used = "global"

        for i, species_set in enumerate(filter_chain):
            is_global = species_set is None
            threshold = GLOBAL_THRESHOLD if is_global else REGIONAL_THRESHOLD

            results = self.classifier.predict_from_logits(
                logits, top_k=top_k, temperature=temperature,
                species_set=species_set
            )

            if results and results[0].get("confidence", 0) / 100.0 >= threshold:
                best_result = results
                if is_global:
                    threshold_used = "global"
                elif i == 0 and len(filter_chain) > 2:
                    threshold_used = "gps"
                else:
                    threshold_used = "country"
                break

        # If nothing met any threshold, use global result anyway (for display)
        if best_result is None:
            best_result = self.classifier.predict_from_logits(
                logits, top_k=top_k, temperature=temperature,
                species_set=None
            )
            threshold_used = "global"

        species = []
        for r in best_result:
            cn_name = r.get("cn_name", "")
            species.append({
                "name": r.get("scientific_name", ""),
                "common_name": r.get("en_name", ""),
                "confidence": float(r.get("confidence", 0)) / 100.0,
                "cn_name": cn_name,
                "pinyin": _to_pinyin(cn_name),
                "threshold_used": threshold_used,
            })
        return {"species": species}
