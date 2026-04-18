import Foundation

struct XMPWriter {

    /// Get the sidecar URL for a photo (replaces extension with .xmp)
    static func sidecarURL(for photo: Photo) -> URL {
        let original = URL(fileURLWithPath: photo.filePath)
        return original.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Generate XMP string for a photo
    static func generate(photo: Photo) -> String {
        let assigned = photo.assignedSpecies
        let hasKeywords = !assigned.isEmpty || photo.isFlying
        let hasLocation = photo.locationCity != nil || photo.locationState != nil
            || photo.locationCountry != nil || photo.locationCountryCode != nil
            || photo.locationSublocation != nil

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
              xmp:Rating="\(photo.starRating)"
              xmp:PickStatus="\(photo.isPick ? 1 : 0)">\n
        """

        if hasKeywords {
            xml += "      <dc:subject>\n"
            xml += "        <rdf:Bag>\n"
            // Emit a keyword per assigned species, deduplicating so a
            // photo tagged with two species whose common names collide
            // doesn't produce duplicate rdf:li entries.
            var emitted = Set<String>()
            for match in assigned {
                if let common = match.commonName, emitted.insert(common).inserted {
                    xml += "          <rdf:li>\(xmlEscape(common))</rdf:li>\n"
                }
                if emitted.insert(match.scientificName).inserted {
                    xml += "          <rdf:li>\(xmlEscape(match.scientificName))</rdf:li>\n"
                }
                if let cn = match.cnName, emitted.insert(cn).inserted {
                    xml += "          <rdf:li>\(xmlEscape(cn))</rdf:li>\n"
                }
                if let pinyin = match.pinyin, emitted.insert(pinyin).inserted {
                    xml += "          <rdf:li>\(xmlEscape(pinyin))</rdf:li>\n"
                }
            }
            if photo.isFlying {
                xml += "          <rdf:li>In Flight</rdf:li>\n"
            }
            xml += "        </rdf:Bag>\n"
            xml += "      </dc:subject>\n"

            xml += "      <lr:hierarchicalSubject>\n"
            xml += "        <rdf:Bag>\n"
            var hierEmitted = Set<String>()
            for match in assigned {
                guard let common = match.commonName else { continue }
                if hierEmitted.insert(common).inserted {
                    xml += "          <rdf:li>Bird|\(xmlEscape(common))</rdf:li>\n"
                }
            }
            if photo.isFlying {
                xml += "          <rdf:li>Behavior|In Flight</rdf:li>\n"
            }
            xml += "        </rdf:Bag>\n"
            xml += "      </lr:hierarchicalSubject>\n"
        }

        if hasLocation {
            if let city = photo.locationCity {
                xml += "      <photoshop:City>\(xmlEscape(city))</photoshop:City>\n"
            }
            if let state = photo.locationState {
                xml += "      <photoshop:State>\(xmlEscape(state))</photoshop:State>\n"
            }
            if let country = photo.locationCountry {
                xml += "      <photoshop:Country>\(xmlEscape(country))</photoshop:Country>\n"
            }
            if let code = photo.locationCountryCode {
                xml += "      <Iptc4xmpCore:CountryCode>\(xmlEscape(code))</Iptc4xmpCore:CountryCode>\n"
            }
            if let sub = photo.locationSublocation {
                xml += "      <Iptc4xmpCore:Location>\(xmlEscape(sub))</Iptc4xmpCore:Location>\n"
            }
        }

        xml += """
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """

        return xml
    }

    /// Write XMP sidecar file next to the original.
    /// Returns the URL of the written .xmp file.
    static func write(photo: Photo) throws -> URL {
        let url = sidecarURL(for: photo)
        let content = generate(photo: photo)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Private

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
