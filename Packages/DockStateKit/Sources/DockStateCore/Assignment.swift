/// Maximum-weight assignment for a rectangular score matrix (Hungarian algorithm, O(n³)).
///
/// `scores[i][j]` is the benefit of assigning row i to column j; `nil` forbids the pair.
/// Returns, for every row, the chosen column or nil.
enum Assignment {
    static func solve(_ scores: [[Double?]]) -> [Int?] {
        let rows = scores.count
        guard rows > 0 else { return [] }
        let cols = scores[0].count
        guard cols > 0 else { return Array(repeating: nil, count: rows) }
        let n = max(rows, cols)
        let maxScore = scores.flatMap { $0.compactMap { $0 } }.max() ?? 0
        let forbidden = maxScore * 4 + 1_000_000
        // Convert to a square minimisation problem.
        var cost = Array(repeating: Array(repeating: maxScore, count: n), count: n)
        for i in 0..<rows {
            for j in 0..<cols {
                cost[i][j] = scores[i][j].map { maxScore - $0 } ?? forbidden
            }
        }
        var u = Array(repeating: 0.0, count: n + 1), v = Array(repeating: 0.0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1), way = Array(repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: n + 1)
            var used = Array(repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var result = Array<Int?>(repeating: nil, count: rows)
        for j in 1...n where p[j] > 0 && p[j] <= rows && j <= cols {
            if scores[p[j] - 1][j - 1] != nil { result[p[j] - 1] = j - 1 }
        }
        return result
    }
}
