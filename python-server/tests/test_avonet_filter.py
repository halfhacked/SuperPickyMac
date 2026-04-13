"""Tests for AvonetFilter geographic species filtering."""

import pytest

from birdid.avonet_filter import AvonetFilter


@pytest.fixture
def avonet():
    af = AvonetFilter()
    yield af
    af.close()


class TestGpsSpecies:
    def test_gps_returns_species_set(self, avonet):
        """San Francisco should return >50 species."""
        species = avonet.get_species_by_gps(37.7749, -122.4194)
        assert isinstance(species, set)
        assert len(species) > 50

    def test_gps_returns_empty_for_ocean(self, avonet):
        """Middle of Pacific should return far fewer species than land."""
        species = avonet.get_species_by_gps(0.0, -160.0)
        assert len(species) < 50


class TestCountryEbird:
    def test_country_ebird_returns_species(self, avonet):
        """US GPS should return >100 species via country eBird data."""
        species, code = avonet.get_species_by_country_ebird(
            37.7749, -122.4194
        )
        assert isinstance(species, set)
        assert len(species) > 100
        assert code is not None

    def test_country_ebird_returns_empty_for_unknown(self, avonet):
        """Antarctica should return empty set."""
        species, code = avonet.get_species_by_country_ebird(
            -85.0, 0.0
        )
        assert len(species) == 0


class TestUnavailableDb:
    def test_unavailable_db(self):
        """Nonexistent DB path should return empty sets for DB queries."""
        af = AvonetFilter(db_path="/nonexistent/path/avonet.db")
        # GPS query requires DB — should return empty
        assert af.get_species_by_gps(37.7749, -122.4194) == set()
        # is_available should be False
        assert af.is_available() is False
        af.close()


class TestFilterChain:
    def test_filter_chain_with_gps(self, avonet):
        """With GPS, chain should have at least 2 entries
        (regional + global None)."""
        chain = avonet.get_filter_chain(37.7749, -122.4194)
        assert len(chain) >= 2
        # Last entry is always None (global fallback)
        assert chain[-1] is None
        # At least one non-None entry before global
        non_none = [e for e in chain if e is not None]
        assert len(non_none) >= 1

    def test_filter_chain_without_gps(self, avonet):
        """Without GPS, chain should be [None] only."""
        chain = avonet.get_filter_chain(None, None)
        assert chain == [None]
