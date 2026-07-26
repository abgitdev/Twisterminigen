import Foundation

enum RenderSessionPlanner {
    static let maxGroupSize = 4

    struct Item: Identifiable, Sendable, Equatable {
        let id: UUID
        let queueJobID: UUID?
        let recipe: GenerationRecipe

        var prompt: String { recipe.prompts.positive }
        var width: Int { recipe.canvas.width }
        var height: Int { recipe.canvas.height }
        var steps: Int { recipe.sampler.steps }

        var seed: UInt64 {
            guard case .fixed(let seed) = recipe.sampler.seed else {
                preconditionFailure("A planned render item must contain a fixed seed")
            }
            return seed
        }

        init(
            id: UUID = UUID(),
            queueJobID: UUID? = nil,
            recipe: GenerationRecipe
        ) {
            precondition(recipe.sampler.seed.fixedValue != nil)
            self.id = id
            self.queueJobID = queueJobID
            self.recipe = recipe
        }

        /// Compatibility initializer for the original Turbo-only render path.
        init(
            id: UUID = UUID(),
            queueJobID: UUID? = nil,
            prompt: String,
            width: Int,
            height: Int,
            steps: Int,
            seed: UInt64
        ) {
            self.init(
                id: id,
                queueJobID: queueJobID,
                recipe: QueueJob.legacyTurboRecipe(
                    prompt: prompt,
                    width: width,
                    height: height,
                    steps: steps,
                    seed: .fixed(seed)))
        }
    }

    static func directGroups(
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        baseSeed: UInt64,
        count: Int
    ) -> [[Item]] {
        let recipe = QueueJob.legacyTurboRecipe(
            prompt: prompt,
            width: width,
            height: height,
            steps: steps,
            seed: .fixed(baseSeed))
        return directGroups(recipe: recipe, baseSeed: baseSeed, count: count)
    }

    static func directGroups(
        recipe: GenerationRecipe,
        baseSeed: UInt64,
        count: Int
    ) -> [[Item]] {
        let items = (0 ..< max(0, count)).map { index in
            var resolved = recipe
            resolved.sampler.seed = .fixed(baseSeed &+ UInt64(index))
            return Item(recipe: resolved)
        }
        return stride(from: 0, to: items.count, by: maxGroupSize).map { start in
            Array(items[start ..< min(items.count, start + maxGroupSize)])
        }
    }

    static func queueGroup(
        firstJob: QueueJob,
        firstSeed: UInt64,
        pending: [QueueJob],
        randomSeed: (QueueJob) -> UInt64,
        canInclude: (QueueJob) -> Bool
    ) -> [Item] {
        let sessionKey = firstJob.recipe.sessionKey
        var items = [item(for: firstJob, resolvedSeed: firstSeed)]
        var includedIDs: Set<UUID> = [firstJob.id]

        for job in pending {
            guard items.count < maxGroupSize,
                  !includedIDs.contains(job.id),
                  job.recipe.sessionKey == sessionKey,
                  canInclude(job)
            else { break }
            let resolved = job.recipe.resolvingRandomSeed {
                randomSeed(job)
            }
            items.append(Item(queueJobID: job.id, recipe: resolved))
            includedIDs.insert(job.id)
        }
        return items
    }

    private static func item(for job: QueueJob, resolvedSeed: UInt64) -> Item {
        var recipe = job.recipe
        recipe.sampler.seed = .fixed(resolvedSeed)
        return Item(queueJobID: job.id, recipe: recipe)
    }
}
