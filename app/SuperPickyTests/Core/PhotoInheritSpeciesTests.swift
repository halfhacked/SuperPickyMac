import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoInheritSpeciesTests {

    private func makePhoto(
        name: String,
        species: String? = nil,
        cn: String? = nil,
        conf: Float? = nil
    ) -> Photo {
        var p = Photo(filename: name, filePath: "/tmp/\(name)", folderPath: "/tmp")
        p.speciesCommonName = species
        p.speciesCnName = cn
        p.speciesScientificName = species.map { "Genus \($0)" }
        p.speciesPinyin = cn.map { "pinyin\($0)" }
        p.speciesConfidence = conf
        return p
    }

    @Test func inheritSpeciesCopiesAllFields() {
        var unidentified = makePhoto(name: "a.jpg")
        let donor = makePhoto(name: "b.jpg", species: "Turkey Vulture",
                              cn: "红头美洲鹫", conf: 0.91)
        unidentified.inheritSpecies(from: donor)

        #expect(unidentified.speciesCommonName == "Turkey Vulture")
        #expect(unidentified.speciesScientificName == "Genus Turkey Vulture")
        #expect(unidentified.speciesCnName == "红头美洲鹫")
        #expect(unidentified.speciesPinyin == "pinyin红头美洲鹫")
        #expect(unidentified.speciesConfidence == 0.91)
    }

    @Test func hasSpeciesReflectsCommonOrScientific() {
        var p = makePhoto(name: "a.jpg")
        #expect(p.hasSpecies == false)

        p.speciesScientificName = "Cathartes aura"
        #expect(p.hasSpecies == true)

        p.speciesScientificName = nil
        p.speciesCommonName = "Turkey Vulture"
        #expect(p.hasSpecies == true)
    }

    @Test func inheritOverridesEvenPartialSpecies() {
        // Current semantics: inheritance unconditionally overwrites.
        // Callers are responsible for guarding via `!hasSpecies`.
        var partial = makePhoto(name: "a.jpg", species: "Unknown Sparrow")
        let donor = makePhoto(name: "b.jpg", species: "White-crowned Sparrow",
                              conf: 0.6)
        partial.inheritSpecies(from: donor)
        #expect(partial.speciesCommonName == "White-crowned Sparrow")
    }
}
