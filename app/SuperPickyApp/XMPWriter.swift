import Foundation

struct XMPWriter {
    private static let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let xmpURI = "http://ns.adobe.com/xap/1.0/"
    private static let dcURI = "http://purl.org/dc/elements/1.1/"
    private static let lrURI = "http://ns.adobe.com/lightroom/1.0/"
    private static let photoshopURI = "http://ns.adobe.com/photoshop/1.0/"
    private static let iptcURI = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    private static let superPickyURI = "https://halfhacked.com/ns/superpicky/1.0/"
    // Track only values inserted by SuperPicky so an identical user keyword
    // remains untouched when a species assignment is later removed.
    private static let managedSubjectName = "ManagedSubject"
    private static let managedHierarchicalSubjectName = "ManagedHierarchicalSubject"

    private enum MergeError: LocalizedError {
        case missingDescription
        case invalidKeywordContainer(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .missingDescription:
                return "The existing sidecar is not a supported XMP document."
            case .invalidKeywordContainer(let name):
                return "The existing XMP \(name) property is not an RDF bag."
            case .encodingFailed:
                return "Could not encode the XMP sidecar as UTF-8."
            }
        }
    }

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
        let flatKeywords = hasKeywords ? keywordBag(for: assigned, isFlying: photo.isFlying) : []
        let hierarchicalKeywords = hasKeywords
            ? hierarchicalBag(for: assigned, isFlying: photo.isFlying)
            : []

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
              xmlns:sp="https://halfhacked.com/ns/superpicky/1.0/"
              xmp:Rating="\(photo.starRating)"
              xmp:PickStatus="\(photo.pickStatus.rawValue)"
              sp:ManagedSubject="\(encodeManaged(flatKeywords))"
              sp:ManagedHierarchicalSubject="\(encodeManaged(hierarchicalKeywords))">\n
        """

        if hasKeywords {
            xml += "      <dc:subject>\n"
            xml += "        <rdf:Bag>\n"
            for keyword in flatKeywords {
                xml += "          <rdf:li>\(xmlEscape(keyword))</rdf:li>\n"
            }
            xml += "        </rdf:Bag>\n"
            xml += "      </dc:subject>\n"

            xml += "      <lr:hierarchicalSubject>\n"
            xml += "        <rdf:Bag>\n"
            for keyword in hierarchicalKeywords {
                xml += "          <rdf:li>\(xmlEscape(keyword))</rdf:li>\n"
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
    static func write(
        photo: Photo,
        replacingSpecies: [SpeciesMatch] = []
    ) throws -> URL {
        let url = sidecarURL(for: photo)
        let data: Data
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            data = try merge(
                photo: photo,
                into: existing,
                replacingSpecies: replacingSpecies
            )
        } else {
            guard let generated = generate(photo: photo).data(using: .utf8) else {
                throw MergeError.encodingFailed
            }
            data = generated
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Flat `dc:subject` keyword list for the XMP sidecar. Pinyin initials ride
    /// with pinyin — both appear together or neither does, so a species removal
    /// drops both from the regenerated sidecar with no separate cleanup.
    static func keywordBag(for assigned: [SpeciesMatch], isFlying: Bool) -> [String] {
        var emitted = Set<String>()
        var bag: [String] = []
        func push(_ value: String?) {
            guard let value, emitted.insert(value).inserted else { return }
            bag.append(value)
        }
        for match in assigned {
            push(match.commonName)
            push(match.scientificName)
            push(match.cnName)
            if let pinyin = match.pinyin {
                push(pinyin)
                push(match.pinyinInitials)
            }
        }
        if isFlying { bag.append("In Flight") }
        return bag
    }

    /// `lr:hierarchicalSubject` keyword list. Emits `Bird|<commonName>` per
    /// species (skipping entries without a common name) and `Behavior|In Flight`
    /// when applicable, deduped by common name.
    static func hierarchicalBag(for assigned: [SpeciesMatch], isFlying: Bool) -> [String] {
        var emitted = Set<String>()
        var bag: [String] = []
        for match in assigned {
            guard let common = match.commonName, emitted.insert(common).inserted else { continue }
            bag.append("Bird|\(common)")
        }
        if isFlying { bag.append("Behavior|In Flight") }
        return bag
    }

    // MARK: - Private

    private static func merge(
        photo: Photo,
        into data: Data,
        replacingSpecies: [SpeciesMatch]
    ) throws -> Data {
        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        let descriptions = descendantElements(
            in: document,
            localName: "Description",
            uri: rdfURI
        )
        guard let primaryDescription = descriptions.first else {
            throw MergeError.missingDescription
        }

        setSimpleProperty(
            localName: "Rating",
            uri: xmpURI,
            preferredPrefix: "xmp",
            value: String(photo.starRating),
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setSimpleProperty(
            localName: "PickStatus",
            uri: xmpURI,
            preferredPrefix: "xmp",
            value: String(photo.pickStatus.rawValue),
            descriptions: descriptions,
            fallback: primaryDescription
        )

        let previousFlat = decodeManagedProperty(
            localName: managedSubjectName,
            descriptions: descriptions
        )
        let previousHierarchical = decodeManagedProperty(
            localName: managedHierarchicalSubjectName,
            descriptions: descriptions
        )
        let assigned = photo.assignedSpecies
        let replacedFlat = keywordBag(for: replacingSpecies, isFlying: photo.isFlying)
        let replacedHierarchical = hierarchicalBag(
            for: replacingSpecies,
            isFlying: photo.isFlying
        )
        let desiredFlat = keywordBag(for: assigned, isFlying: photo.isFlying)
        let desiredHierarchical = hierarchicalBag(for: assigned, isFlying: photo.isFlying)
        let managedFlat = try updateKeywordBag(
            propertyName: "subject",
            propertyURI: dcURI,
            preferredPrefix: "dc",
            desired: desiredFlat,
            removing: (previousFlat ?? []) + replacedFlat,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        let managedHierarchical = try updateKeywordBag(
            propertyName: "hierarchicalSubject",
            propertyURI: lrURI,
            preferredPrefix: "lr",
            desired: desiredHierarchical,
            removing: (previousHierarchical ?? []) + replacedHierarchical,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setSimpleProperty(
            localName: managedSubjectName,
            uri: superPickyURI,
            preferredPrefix: "sp",
            value: encodeManaged(managedFlat),
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setSimpleProperty(
            localName: managedHierarchicalSubjectName,
            uri: superPickyURI,
            preferredPrefix: "sp",
            value: encodeManaged(managedHierarchical),
            descriptions: descriptions,
            fallback: primaryDescription
        )

        setOptionalElementProperty(
            localName: "City",
            uri: photoshopURI,
            preferredPrefix: "photoshop",
            value: photo.locationCity,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setOptionalElementProperty(
            localName: "State",
            uri: photoshopURI,
            preferredPrefix: "photoshop",
            value: photo.locationState,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setOptionalElementProperty(
            localName: "Country",
            uri: photoshopURI,
            preferredPrefix: "photoshop",
            value: photo.locationCountry,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setOptionalElementProperty(
            localName: "CountryCode",
            uri: iptcURI,
            preferredPrefix: "Iptc4xmpCore",
            value: photo.locationCountryCode,
            descriptions: descriptions,
            fallback: primaryDescription
        )
        setOptionalElementProperty(
            localName: "Location",
            uri: iptcURI,
            preferredPrefix: "Iptc4xmpCore",
            value: photo.locationSublocation,
            descriptions: descriptions,
            fallback: primaryDescription
        )

        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func updateKeywordBag(
        propertyName: String,
        propertyURI: String,
        preferredPrefix: String,
        desired: [String],
        removing: [String],
        descriptions: [XMLElement],
        fallback: XMLElement
    ) throws -> [String] {
        let existingProperty = descriptions.compactMap {
            directElement(in: $0, localName: propertyName, uri: propertyURI)
        }.first

        let property: XMLElement
        let bag: XMLElement
        if let existingProperty {
            property = existingProperty
            guard let existingBag = directElement(
                in: property,
                localName: "Bag",
                uri: rdfURI
            ) else {
                throw MergeError.invalidKeywordContainer(propertyName)
            }
            bag = existingBag
        } else {
            guard !desired.isEmpty else { return [] }
            let propertyPrefix = ensureNamespace(
                preferredPrefix,
                uri: propertyURI,
                on: fallback
            )
            property = XMLElement(
                name: "\(propertyPrefix):\(propertyName)",
                uri: propertyURI
            )
            let rdfPrefix = ensureNamespace("rdf", uri: rdfURI, on: fallback)
            bag = XMLElement(name: "\(rdfPrefix):Bag", uri: rdfURI)
            property.addChild(bag)
            fallback.addChild(property)
        }

        if !removing.isEmpty {
            let removedValues = Set(removing)
            let items = directElements(in: bag, localName: "li", uri: rdfURI)
            for item in items.reversed() {
                guard let value = item.stringValue,
                      removedValues.contains(value) else { continue }
                item.detach()
            }
        }

        var present = Set(
            directElements(in: bag, localName: "li", uri: rdfURI)
                .compactMap(\.stringValue)
        )
        var managed: [String] = []
        let owner = property.parent as? XMLElement ?? fallback
        let rdfPrefix = ensureNamespace("rdf", uri: rdfURI, on: owner)
        for value in desired {
            if present.insert(value).inserted {
                let item = XMLElement(name: "\(rdfPrefix):li", uri: rdfURI)
                item.stringValue = value
                bag.addChild(item)
            }
            managed.append(value)
        }
        return managed
    }

    /// Finds an existing attribute or child element with the given name/URI across
    /// `descriptions`, sets its value, and returns `true` when found.
    @discardableResult
    private static func updateExistingProperty(
        localName: String,
        uri: String,
        value: String,
        in descriptions: [XMLElement]
    ) -> Bool {
        if let attribute = descriptions.compactMap({
            namespacedAttribute(in: $0, localName: localName, uri: uri)
        }).first {
            attribute.stringValue = value
            return true
        }
        if let element = descriptions.compactMap({
            directElement(in: $0, localName: localName, uri: uri)
        }).first {
            element.stringValue = value
            return true
        }
        return false
    }

    private static func setSimpleProperty(
        localName: String,
        uri: String,
        preferredPrefix: String,
        value: String,
        descriptions: [XMLElement],
        fallback: XMLElement
    ) {
        if updateExistingProperty(localName: localName, uri: uri, value: value, in: descriptions) { return }
        let prefix = ensureNamespace(preferredPrefix, uri: uri, on: fallback)
        let attribute = XMLNode.attribute(
            withName: "\(prefix):\(localName)",
            uri: uri,
            stringValue: value
        ) as! XMLNode
        fallback.addAttribute(attribute)
    }

    private static func setOptionalElementProperty(
        localName: String,
        uri: String,
        preferredPrefix: String,
        value: String?,
        descriptions: [XMLElement],
        fallback: XMLElement
    ) {
        guard let value else { return }
        if updateExistingProperty(localName: localName, uri: uri, value: value, in: descriptions) { return }
        let prefix = ensureNamespace(preferredPrefix, uri: uri, on: fallback)
        let element = XMLElement(name: "\(prefix):\(localName)", uri: uri)
        element.stringValue = value
        fallback.addChild(element)
    }

    private static func decodeManagedProperty(
        localName: String,
        descriptions: [XMLElement]
    ) -> [String]? {
        guard let encoded = descriptions.compactMap({
            namespacedAttribute(
                in: $0,
                localName: localName,
                uri: superPickyURI
            )?.stringValue
        }).first else {
            return nil
        }
        guard !encoded.isEmpty else { return [] }
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded.split(
            separator: "\0",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private static func encodeManaged(_ values: [String]) -> String {
        Data(values.joined(separator: "\0").utf8).base64EncodedString()
    }

    private static func descendantElements(
        in node: XMLNode,
        localName: String,
        uri: String
    ) -> [XMLElement] {
        var matches: [XMLElement] = []
        if let element = node as? XMLElement,
           element.localName == localName,
           element.uri == uri {
            matches.append(element)
        }
        for child in node.children ?? [] {
            matches.append(contentsOf: descendantElements(
                in: child,
                localName: localName,
                uri: uri
            ))
        }
        return matches
    }

    private static func directElements(
        in element: XMLElement,
        localName: String,
        uri: String
    ) -> [XMLElement] {
        (element.children ?? []).compactMap {
            guard let child = $0 as? XMLElement,
                  child.localName == localName,
                  child.uri == uri else { return nil }
            return child
        }
    }

    private static func directElement(
        in element: XMLElement,
        localName: String,
        uri: String
    ) -> XMLElement? {
        directElements(in: element, localName: localName, uri: uri).first
    }

    private static func namespacedAttribute(
        in element: XMLElement,
        localName: String,
        uri: String
    ) -> XMLNode? {
        element.attributes?.first {
            $0.localName == localName && $0.uri == uri
        }
    }

    private static func ensureNamespace(
        _ preferredPrefix: String,
        uri: String,
        on element: XMLElement
    ) -> String {
        if let existing = element.resolvePrefix(forNamespaceURI: uri),
           !existing.isEmpty {
            return existing
        }

        var prefix = preferredPrefix
        var suffix = 2
        while let mappedURI = namespaceURI(for: prefix, from: element),
              mappedURI != uri {
            prefix = "\(preferredPrefix)\(suffix)"
            suffix += 1
        }
        if namespaceURI(for: prefix, from: element) == nil {
            let namespace = XMLNode.namespace(
                withName: prefix,
                stringValue: uri
            ) as! XMLNode
            element.addNamespace(namespace)
        }
        return prefix
    }

    private static func namespaceURI(
        for prefix: String,
        from element: XMLElement
    ) -> String? {
        var node: XMLNode? = element
        while let current = node {
            if let currentElement = current as? XMLElement,
               let namespace = currentElement.namespaces?.first(where: {
                   $0.name == prefix
               }) {
                return namespace.stringValue
            }
            node = current.parent
        }
        return nil
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
