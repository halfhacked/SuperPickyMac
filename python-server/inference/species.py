"""Species identification using preen's OSEA classifier with GPS-based filtering."""
from PIL import Image
from io import BytesIO
from inference.device import get_best_device
from pypinyin import pinyin, Style

from preen.birdid.osea_classifier import OSEAClassifier
from preen.birdid.avonet_filter import AvonetFilter

REGIONAL_THRESHOLD = 0.80
GLOBAL_THRESHOLD = 0.90


def _to_pinyin(cn_name: str) -> str:
    if not cn_name:
        return ""
    return "".join(p[0] for p in pinyin(cn_name, style=Style.NORMAL, errors="ignore"))


def _build_filter_chain(avonet: AvonetFilter, lat, lon):
    """Return progressively broader species filters: GPS grid -> country -> global(None)."""
    chain = []
    if lat is not None and lon is not None:
        gps_species = avonet.get_species_by_gps(lat, lon)
        if gps_species:
            chain.append(gps_species)
        country_species, _ = avonet.get_species_by_country_ebird(lat, lon)
        if country_species and country_species != gps_species:
            chain.append(country_species)
    chain.append(None)
    return chain


class SpeciesClassifier:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        self.classifier = OSEAClassifier(model_path=model_path, device=self.device)
        self._avonet = None

    def _get_avonet(self):
        if self._avonet is None:
            self._avonet = AvonetFilter()
        return self._avonet

    def predict(self, image_bytes: bytes, top_k: int = 5,
                temperature: float = 0.9,
                lat: float = None, lon: float = None) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")
        logits = self.classifier.get_logits(image)

        avonet = self._get_avonet()
        filter_chain = _build_filter_chain(avonet, lat, lon)

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

        if best_result is None:
            # Nothing met threshold — return best global guess anyway so caller
            # can decide whether to show it (with low confidence indicator)
            best_result = self.classifier.predict_from_logits(
                logits, top_k=top_k, temperature=temperature, species_set=None
            )
            threshold_used = "below_threshold"

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
