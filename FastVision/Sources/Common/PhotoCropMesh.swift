import CoreImage

/// Maps a rectangular output grid to the selected area of the source photo.
struct PhotoCropMesh {
    static let divisions = 4
    static let side = divisions + 1

    struct Node {
        let point: CGPoint
        // The homogeneous weight keeps an untouched grid equivalent to a single homography.
        let weight: CGFloat
    }

    let nodes: [Node]

    init?(corners: [CGPoint], adjustments: [Int: CGPoint]) {
        guard corners.count == 4 else { return nil }
        let topLeft = corners[0], topRight = corners[1]
        let bottomRight = corners[2], bottomLeft = corners[3]
        let dx1 = topRight.x - bottomRight.x, dx2 = bottomLeft.x - bottomRight.x
        let dy1 = topRight.y - bottomRight.y, dy2 = bottomLeft.y - bottomRight.y
        let dx3 = topLeft.x - topRight.x + bottomRight.x - bottomLeft.x
        let dy3 = topLeft.y - topRight.y + bottomRight.y - bottomLeft.y
        let determinant = dx1 * dy2 - dx2 * dy1
        guard abs(determinant) > 0.00000001 else { return nil }

        let g = (dx3 * dy2 - dx2 * dy3) / determinant
        let h = (dx1 * dy3 - dx3 * dy1) / determinant
        let ax = topRight.x - topLeft.x + g * topRight.x
        let bx = bottomLeft.x - topLeft.x + h * bottomLeft.x
        let ay = topRight.y - topLeft.y + g * topRight.y
        let by = bottomLeft.y - topLeft.y + h * bottomLeft.y

        let side = Self.side
        let divisions = Self.divisions
        var base: [Node] = []
        for row in 0..<side {
            let v = CGFloat(row) / CGFloat(divisions)
            for column in 0..<side {
                let u = CGFloat(column) / CGFloat(divisions)
                let weight = 1 + g * u + h * v
                guard weight.isFinite, weight > 0.00000001 else { return nil }
                let x = (topLeft.x + ax * u + bx * v) / weight
                let y = (topLeft.y + ay * u + by * v) / weight
                guard (-1e-10...1 + 1e-10).contains(x), (-1e-10...1 + 1e-10).contains(y) else { return nil }
                base.append(Node(point: CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))), weight: weight))
            }
        }
        // Preserve the user's exact corner positions, including when they lie on the image border.
        for (corner, point) in corners.enumerated() {
            let index = Self.boundaryIndex(edge: corner, offset: 0)
            base[index] = Node(point: point, weight: base[index].weight)
        }

        guard !adjustments.isEmpty else {
            nodes = base
            return
        }

        let displacements = base.enumerated().map { index, node in
            guard let point = adjustments[index] else { return CGPoint.zero }
            return CGPoint(x: point.x - node.point.x, y: point.y - node.point.y)
        }
        var adjusted = base
        for row in 0..<side {
            let v = CGFloat(row) / CGFloat(divisions)
            for column in 0..<side {
                let u = CGFloat(column) / CGFloat(divisions)
                let index = row * side + column
                let node = base[index]
                let top = displacements[column]
                let bottom = displacements[divisions * side + column]
                let left = displacements[row * side]
                let right = displacements[row * side + divisions]
                let point = adjustments[index] ?? CGPoint(
                    x: node.point.x + (1 - v) * top.x + v * bottom.x + (1 - u) * left.x + u * right.x,
                    y: node.point.y + (1 - v) * top.y + v * bottom.y + (1 - u) * left.y + u * right.y
                )
                guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
                adjusted[index] = Node(point: point, weight: node.weight)
            }
        }
        nodes = adjusted

        // Positive weights and convex cells keep the mapping continuous and prevent local folds.
        // The perimeter check also rejects intersections between distant cells.
        guard hasConvexCells, hasSimpleBoundary else { return nil }
    }

    static func boundaryIndex(edge: Int, offset: Int) -> Int {
        switch edge {
        case 0: return offset
        case 1: return offset * side + divisions
        case 2: return divisions * side + divisions - offset
        default: return (divisions - offset) * side
        }
    }

    func point(row: Int, column: Int) -> CGPoint { nodes[row * Self.side + column].point }

    func edgePoints(_ edge: Int) -> [CGPoint] {
        (0...Self.divisions).map { nodes[Self.boundaryIndex(edge: edge, offset: $0)].point }
    }

    var boundary: [CGPoint] {
        (0..<4).flatMap { edge in
            (0..<Self.divisions).map { nodes[Self.boundaryIndex(edge: edge, offset: $0)].point }
        }
    }

    private func cellIndices(row: Int, column: Int) -> [Int] {
        let topLeft = row * Self.side + column
        return [topLeft, topLeft + 1, topLeft + Self.side + 1, topLeft + Self.side]
    }

    private var hasConvexCells: Bool {
        for row in 0..<Self.divisions {
            for column in 0..<Self.divisions {
                let points = cellIndices(row: row, column: column).map { nodes[$0].point }
                for index in points.indices {
                    guard Self.cross(points[index], points[(index + 1) % 4], points[(index + 2) % 4]) > 1e-8 else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private var hasSimpleBoundary: Bool {
        let points = boundary
        let count = points.count
        for i in 0..<(count - 2) {
            for j in (i + 2)..<count where i != 0 || j != count - 1 {
                if Self.intersects(points[i], points[(i + 1) % count], points[j], points[(j + 1) % count]) {
                    return false
                }
            }
        }
        return true
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        guard max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x)),
              max(min(a.y, b.y), min(c.y, d.y)) <= min(max(a.y, b.y), max(c.y, d.y)) else { return false }
        return cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0
    }

    func warp(_ image: CIImage, outputSize: CGSize) -> CIImage? {
        let imageExtent = image.extent
        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let sourcePoints = nodes.map {
            CGPoint(x: imageExtent.minX + $0.point.x * imageExtent.width,
                    y: imageExtent.maxY - $0.point.y * imageExtent.height)
        }
        let size = CIVector(x: outputSize.width, y: outputSize.height)
        let controls = zip(sourcePoints, nodes).map { point, node in
            CIVector(x: point.x * node.weight, y: point.y * node.weight, z: node.weight)
        }

        let step = CGSize(width: outputSize.width / CGFloat(Self.divisions),
                          height: outputSize.height / CGFloat(Self.divisions))
        var regions: [(output: CGRect, source: CGRect)] = []
        for row in 0..<Self.divisions {
            for column in 0..<Self.divisions {
                let output = CGRect(x: CGFloat(column) * step.width,
                                    y: CGFloat(Self.divisions - row - 1) * step.height,
                                    width: step.width, height: step.height)
                let points = cellIndices(row: row, column: column).map { sourcePoints[$0] }
                let xs = points.map(\.x), ys = points.map(\.y)
                let x = xs.min()!, y = ys.min()!
                let source = CGRect(x: x, y: y, width: xs.max()! - x, height: ys.max()! - y)
                regions.append((output, source.insetBy(dx: -2, dy: -2).integral))
            }
        }
        return Self.kernel?.apply(extent: outputExtent, roiCallback: { _, rect in
            regions.reduce(CGRect.null) { needed, region in
                region.output.intersects(rect) ? needed.union(region.source) : needed
            }
        }, image: image.clampedToExtent(), arguments: [size] + controls)
    }

    private static let kernel: CIWarpKernel? = {
        let parameters = (0..<(side * side)).map { "vec3 p\($0)" }.joined(separator: ", ")
        var source = """
        kernel vec2 cropMesh(vec2 size, \(parameters)) {
            vec2 coordinate = destCoord() / size;
            vec2 grid = clamp(vec2(coordinate.x, 1.0 - coordinate.y), 0.0, 1.0) * \(divisions).0;
            vec2 cell = min(floor(grid), vec2(\(divisions - 1).0));
            vec2 t = grid - cell;
            vec3 q;
        """
        for row in 0..<divisions {
            for column in 0..<divisions {
                let topLeft = row * side + column
                let topRight = topLeft + 1
                let bottomLeft = topLeft + side
                let bottomRight = bottomLeft + 1
                let isFirst = row == 0 && column == 0
                let isLast = row == divisions - 1 && column == divisions - 1
                let condition = isLast ? "else" : "\(isFirst ? "if" : "else if") (cell.x == \(column).0 && cell.y == \(row).0)"
                source += """

                    \(condition) {
                        q = mix(mix(p\(topLeft), p\(topRight), t.x), mix(p\(bottomLeft), p\(bottomRight), t.x), t.y);
                    }
                """
            }
        }
        source += """

            return q.xy / q.z;
        }
        """
        return CIWarpKernel(source: source)
    }()
}
