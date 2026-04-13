import sys
import os
from PIL import Image
from io import BytesIO
from inference.device import get_best_device
from pypinyin import pinyin, Style

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)

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
        from birdid.osea_classifier import OSEAClassifier
        self.classifier = OSEAClassifier(model_path=model_path, device=self.device)
        self._avonet = None

    def _get_avonet(self):
        if self._avonet is None:
            from birdid.avonet_filter import AvonetFilter
            self._avonet = AvonetFilter()
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
