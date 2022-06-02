import OrderedCollections
import XcodeProj

extension Generator {
    /// Attempts to consolidate targets that differ only by configuration.
    ///
    /// - See: `ConsolidatedTarget`.
    ///
    /// - Parameters:
    ///   - targets: The universe of targets.
    ///   - logger: A `Logger` to output warnings to when certain configuration
    ///     prevents a consolidation.
    static func consolidateTargets(
        _ targets: [TargetID: Target],
        logger: Logger
    ) throws -> ConsolidatedTargets {
        // First pass
        var consolidatable: [ConsolidatableKey: Set<TargetID>] = [:]
        for (id, target) in targets {
            consolidatable[.init(target: target), default: []].insert(id)
        }

        // Filter out multiple archs of the same platform
        // TODO: Eventually we should probably support this, for Universal macOS
        //   binaries. Xcode doesn't respect the `arch` condition for product
        //   directory related build settings, so it's non-trival to support.
        var consolidateGroups: [Set<TargetID>] = []
        for ids in consolidatable.values {
            var platforms: [String: Set<ArchAndTargetID>] = [:]
            for id in ids {
                let platform = targets[id]!.platform
                platforms[platform.name, default: []]
                    .insert(.init(platform.arch, id))
            }

            var consolidateIDs: Set<TargetID> = []
            var uniqueIDs: Set<TargetID> = []
            for archAndIDs in platforms.values {
                guard archAndIDs.count > 1 else {
                    consolidateIDs.insert(archAndIDs.first!.id)
                    continue
                }

                // We will keep the first architecture consolidated
                let sortedIDs = archAndIDs
                    .sorted { lhs, _ in lhs.arch == "arm64" }
                    .map(\.id)
                consolidateIDs.insert(sortedIDs[0])
                uniqueIDs.formUnion(sortedIDs[1...])
            }

            consolidateGroups.append(consolidateIDs)
            uniqueIDs.forEach { consolidateGroups.append([$0]) }
        }

        // Build up mappings
        var targetIDMapping: [TargetID: ConsolidatedTarget.Key] = [:]
        var keys: Set<ConsolidatedTarget.Key> = []
        for ids in consolidateGroups {
            let key = ConsolidatedTarget.Key(ids)
            keys.insert(key)
            for id in ids {
                targetIDMapping[id] = key
            }
        }

        // Calculate dependencies
        func resolveDependency(
            _ depID: TargetID,
            for id: TargetID
        ) throws -> ConsolidatedTarget.Key {
            guard let dependencyKey = targetIDMapping[depID] else {
                throw PreconditionError(message: """
Target "\(id)" dependency on "\(depID)" not found in \
`consolidateTargets().targetIDMapping`
""")
            }
            return dependencyKey
        }

        var testHostMap: [TargetID: ConsolidatedTarget.Key] = [:]
        var depsMap: [TargetID: Set<ConsolidatedTarget.Key>] = [:]
        var rdepsMap: [ConsolidatedTarget.Key: Set<ConsolidatedTarget.Key>] =
            [:]
        for key in keys {
            for id in key.targetIDs {
                guard let target = targets[id] else {
                    throw PreconditionError(message: """
Target "\(id)" not found in `consolidateTargets().targets`
""")
                }

                var dependencies = Set<ConsolidatedTarget.Key>(
                    try target.dependencies.map { depID in
                        return try resolveDependency(depID, for: id)
                    }
                )
                depsMap[id] = dependencies

                if let testHost = target.testHost {
                    let depKey = try resolveDependency(testHost, for: id)
                    testHostMap[id] = depKey
                    dependencies.insert(depKey)
                }

                for dependencyKey in dependencies {
                    rdepsMap[dependencyKey, default: []].insert(key)
                }
            }
        }

        // Account for conditional dependencies
        func deconsolidateKey(_ key: ConsolidatedTarget.Key) {
            keys.remove(key)
            // TODO: Use `depsGrouping` to be more specific with what
            // needs to be reevaluated. As it stands, we just blow away all
            // dependent targets ability to be consolidated.
            for id in key.targetIDs {
                let newKey = ConsolidatedTarget.Key([id])
                keys.insert(newKey)
                targetIDMapping[id] = newKey
            }
            if let rdeps = rdepsMap.removeValue(forKey: key) {
                rdeps.forEach { deconsolidateKey($0) }
            }
        }

        for key in keys.filter({ $0.targetIDs.count > 1 }) {
            var testHostGrouping: [ConsolidatedTarget.Key?: Set<TargetID>] =
                [:]
            var depsGrouping: [Set<ConsolidatedTarget.Key>: Set<TargetID>] = [:]
            for id in key.targetIDs {
                testHostGrouping[testHostMap[id], default: []].insert(id)
                depsGrouping[depsMap[id] ?? [], default: []].insert(id)
            }

            if testHostGrouping.count != 1 {
                logger.logWarning("""
Was unable to consolidate targets \(key.targetIDs.sorted()) since they have a \
conditional `test_host`
""")
                deconsolidateKey(key)
            }

            if depsGrouping.count != 1 {
                logger.logWarning("""
Was unable to consolidate targets \(key.targetIDs.sorted()) since they have a \
conditional `deps`
""")
                deconsolidateKey(key)
            }
        }

        // Create `ConsolidateTarget`s
        var consolidatedTargets: [ConsolidatedTarget.Key: ConsolidatedTarget] =
            [:]
        for key in keys {
            var cTargets: [TargetID: Target] = [:]
            for targetID in key.targetIDs {
                guard let target = targets[targetID] else {
                    throw PreconditionError(message: """
Target "\(targetID)" not found in `consolidateTargets().targets`
""")
                }
                cTargets[targetID] = target
            }

            consolidatedTargets[key] = ConsolidatedTarget(targets: cTargets)
        }

        return ConsolidatedTargets(
            keys: targetIDMapping,
            targets: consolidatedTargets
        )
    }
}

// MARK: - Computation

/// If multiple `Targets` have the same `ConsolidatableKey`, they can
/// potentially be consolidated. "Potentially", since there are some
/// disqualifying properties that require further inspection (e.g conditional
/// dependencies).
private struct ConsolidatableKey: Equatable, Hashable {
    let label: String
    let productType: PBXProductType
}

extension ConsolidatableKey {
    init(target: Target) {
        label = target.label
        productType = target.product.type
    }
}

private struct ArchAndTargetID: Equatable, Hashable {
    let arch: String
    let id: TargetID

    init(_ arch: String, _ id: TargetID) {
        self.arch = arch
        self.id = id
    }
}

struct ConsolidatedTargets: Equatable {
    let keys: [TargetID: ConsolidatedTarget.Key]
    let targets: [ConsolidatedTarget.Key: ConsolidatedTarget]
}

/// Collects multiple Bazel targets (see `Target`) that can be represented by
/// a single Xcode target (see `PBXNativeTarget`).
///
/// In a Bazel build graph there might be multiple configurations of the
/// same label (e.g. macOS and iOS flavors of the same `swift_library`).
/// Xcode can represent these various configurations as a single target,
/// using build settings, and conditionals on build settings, to account
/// for the differences.
struct ConsolidatedTarget: Equatable {
    struct Key: Equatable, Hashable {
        fileprivate let targetIDs: Set<TargetID>
    }

    let name: String
    let label: String
    let product: ConsolidatedTargetProduct
    let isSwift: Bool
    let resourceBundles: Set<FilePath>
    let inputs: ConsolidatedTargetInputs
    let linkerInputs: ConsolidatedTargetLinkerInputs
    let outputs: ConsolidatedTargetOutputs

    /// The `Set` of `FilePath`s that each target references above the baseline.
    ///
    /// The baseline is all `FilePath`s that each target references. A reference
    /// in this case is anything that the `EXCLUDED_SOURCE_FILE_NAMES` and
    /// `INCLUDED_SOURCE_FILE_NAMES` apply to.
    let uniqueFiles: [TargetID: Set<FilePath>]

    let targets: [TargetID: Target]

    /// There are a couple places that want to use the "best" target for a
    /// value (i.e. the one most likely to be built), so we store the sorted
    /// targets as an optimization.
    let sortedTargets: [Target]
}

extension ConsolidatedTarget.Key {
    init(_ targetIDs: Set<TargetID>) {
        self.targetIDs = targetIDs
    }
}

extension ConsolidatedTarget {
    init(targets: [TargetID: Target]) {
        self.targets = targets
        let aTarget = self.targets.first!.value

        name = aTarget.name
        label = aTarget.label
        product = ConsolidatedTargetProduct(
            name: aTarget.product.name,
            type: aTarget.product.type,
            basename: aTarget.product.path.path.lastComponent,
            paths: Set(targets.values.map(\.product.path))
        )
        isSwift = aTarget.isSwift

        var resourceBundles: Set<FilePath> = []
        targets.values.forEach { resourceBundles.formUnion($0.resourceBundles) }
        self.resourceBundles = resourceBundles

        sortedTargets = targets
            .sorted { lhs, rhs in
                return lhs.value.buildSettingConditional <
                    rhs.value.buildSettingConditional
            }
            .map { $1 }
        inputs = Self.consolidateInputs(targets: sortedTargets)
        linkerInputs = Self.consolidateLinkerInputs(targets: sortedTargets)

        var baselineFiles: Set<FilePath> = aTarget.allExcludableFiles
        for target in targets.values {
            baselineFiles.formIntersection(target.allExcludableFiles)
        }

        var uniqueFiles: [TargetID: Set<FilePath>] = [:]
        for (id, target) in targets {
            uniqueFiles[id] = target.allExcludableFiles
                .subtracting(baselineFiles)
        }
        self.uniqueFiles = uniqueFiles

        outputs = ConsolidatedTargetOutputs(
            hasOutputs: self.targets.values.contains { $0.outputs.hasOutputs },
            hasSwiftOutputs: self.targets.values
                .contains { $0.outputs.hasSwiftOutputs }
        )
    }

    private static func consolidateInputs(
        targets: [Target]
    ) -> ConsolidatedTargetInputs {
        return ConsolidatedTargetInputs(
            srcs: consolidateFiles(targets.map(\.inputs.srcs)),
            nonArcSrcs: consolidateFiles(targets.map(\.inputs.nonArcSrcs)),
            hdrs: targets.reduce(into: []) { all, target in
                return all.formUnion(target.inputs.hdrs)
            },
            resources: targets.reduce(into: []) { all, target in
                return all.formUnion(target.inputs.resources)
            }
        )
    }

    private static func consolidateLinkerInputs(
        targets: [Target]
    ) -> ConsolidatedTargetLinkerInputs {
        return ConsolidatedTargetLinkerInputs(
            staticFrameworks: consolidateFiles(
                targets.map(\.linkerInputs.staticFrameworks)
            ),
            dynamicFrameworks: consolidateFiles(
                targets.map(\.linkerInputs.dynamicFrameworks)
            )
        )
    }

    private static func consolidateFiles(_ files: [[FilePath]]) -> [FilePath] {
        guard !files.isEmpty else {
            return []
        }

        // First generate the baseline
        var baselineFiles = OrderedSet(files[0])
        for files in files {
            baselineFiles.formIntersection(files)
        }

        var consolidatedFiles = baselineFiles

        // For each array of `files`, insert them into `consolidatedFiles`,
        // preserving relative order
        for files in files {
            var consolidatedIdx = 0
            var filesIdx = 0
            while consolidatedIdx < consolidatedFiles.count &&
                    filesIdx < files.count
            {
                let file = files[filesIdx]
                filesIdx += 1

                guard consolidatedFiles[consolidatedIdx] != file else {
                    consolidatedIdx += 1
                    continue
                }

                if baselineFiles.contains(file) {
                    // We need to adjust out index based on where the file
                    // exists in the baseline
                    let foundIndex = consolidatedFiles.firstIndex(of: file)!
                    if foundIndex > consolidatedIdx {
                        consolidatedIdx = foundIndex + 1
                    }
                    continue
                }

                let (inserted, _) = consolidatedFiles.insert(
                    file,
                    at: consolidatedIdx
                )
                if inserted {
                    consolidatedIdx += 1
                }
            }

            if filesIdx < files.count {
                consolidatedFiles.append(contentsOf: files[filesIdx...])
            }
        }

        return consolidatedFiles.elements
    }
}

struct ConsolidatedTargetProduct: Equatable {
    let name: String
    let type: PBXProductType
    let basename: String
    let paths: Set<FilePath>
}

struct ConsolidatedTargetInputs: Equatable {
    let srcs: [FilePath]
    let nonArcSrcs: [FilePath]
    let hdrs: Set<FilePath>
    let resources: Set<FilePath>
}

struct ConsolidatedTargetLinkerInputs: Equatable {
    let staticFrameworks: [FilePath]
    let dynamicFrameworks: [FilePath]
}

struct ConsolidatedTargetOutputs: Equatable {
    let hasOutputs: Bool
    let hasSwiftOutputs: Bool
}

// MARK: - Private extensions

private extension Target {
    var allExcludableFiles: Set<FilePath> {
        var files = inputs.all
        files.formUnion(linkerInputs.allExcludableFiles)
        files.formUnion(resourceBundles)
        return files
    }
}

private extension LinkerInputs {
    var allExcludableFiles: Set<FilePath> {
        return Set(dynamicFrameworks)
    }
}
