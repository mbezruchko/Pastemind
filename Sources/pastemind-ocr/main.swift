import AppKit
import PDFKit
import Vision

// pastemind-ocr <file> [first page] [pages] [characters] [--gentle] [--stats]
//   The text in a scanned PDF's pages (from `first page`, counted from 0, at most `pages` of them, stopping once there's
//   `characters` of it) or in a picture, by Vision, to stdout: each page's lines, the pages separated by form feeds.
//   The app runs it as a process of its own (`TextRecognition`): Vision's models (~250 MB) go when it's done.
//   `--gentle`: at background priority (a low-power core, about five times slower), while you work.
//   `--stats`: what each page took, to stderr.

let options = Set(CommandLine.arguments.filter { $0.hasPrefix("--") })
let arguments = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: pastemind-ocr <file> [first page] [pages] [characters] [--gentle]\n".utf8))
    exit(2)
}
if options.contains("--gentle") { setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) }
let url = URL(fileURLWithPath: arguments[1])
let first = arguments.count > 2 ? max(0, Int(arguments[2]) ?? 0) : 0
let pages = arguments.count > 3 ? max(1, Int(arguments[3]) ?? 1) : 1
let characters = arguments.count > 4 ? Int(arguments[4]) ?? .max : .max
let stats = options.contains("--stats")
let parent = getppid()

func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\u{0C}\n").utf8))
}

let header = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 5)
if header == Data("%PDF-".utf8), let document = PDFDocument(url: url) {
    var found = 0
    for index in first..<min(document.pageCount, first + pages) where found < characters {
        // The app quit (or gave up on it): no one's reading.
        guard getppid() == parent else { exit(0) }
        let start = Date()
        let text = autoreleasepool { document.page(at: index).flatMap(Recognizer.render).map(Recognizer.text) ?? "" }
        if stats { Recognizer.report("page \(index + 1)", text, since: start) }
        emit(text)
        found += text.count
    }
} else if let picture = Recognizer.picture(url) {
    let start = Date()
    let text = Recognizer.text(in: picture)
    if stats { Recognizer.report("picture", text, since: start) }
    emit(text)
} else {
    exit(1)
}

enum Recognizer {
    /// A page as Vision reads it best: about 200 dpi (text at 9 pt is some 25 pixels tall), no side over 3,000 pixels.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let side = min(3000, max(box.width, box.height) * 200 / 72)
        guard side > 0 else { return nil }
        return page.thumbnail(of: CGSize(width: side, height: side), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A picture, no side over 4,096 pixels.
    static func picture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated(unsafe) static var fallbacks = 0

    static func report(_ what: String, _ text: String, since start: Date) {
        let line = String(format: "%@: %d characters, %.0f ms, %d fallback reads\n", what, text.count,
                          Date().timeIntervalSince(start) * 1000, fallbacks)
        FileHandle.standardError.write(Data(line.utf8))
        fallbacks = 0
    }

    struct Line {
        var text: String
        /// Its corners, in pixels from the top left: top left, top right, bottom right, bottom left.
        var corners: [CGPoint]
        var box: CGRect {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }

        init(text: String, corners: [CGPoint]) {
            self.text = text
            self.corners = corners
        }

        init(text: String, box: CGRect) {
            self.init(text: text, corners: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)])
        }

        /// Turned `angle` (radians) anticlockwise about `center`, as `Recognizer.straightened` turns the page.
        func turned(by angle: CGFloat, around center: CGPoint) -> Line {
            Line(text: text, corners: corners.map { point in
                let dx = point.x - center.x, dy = point.y - center.y
                return CGPoint(x: center.x + dx * cos(angle) + dy * sin(angle),
                               y: center.y - dx * sin(angle) + dy * cos(angle))
            })
        }
    }

    /// Its lines, in reading order. Vision reads a page whole, but drops lines set too close together (it takes a few
    /// for one, can't read that, and leaves them out: three lines of a cramped paragraph, or a whole cramped page):
    /// where there's ink none of its lines cover, the lines there are read again, spaced apart.
    static func text(in image: CGImage) -> String {
        var lines = recognize(image)
        // A page scanned askew: rows of pixels cut across its lines. Set straight by their slant to look for what was
        // left out.
        var image = image
        let slant = slant(of: lines, width: CGFloat(image.width))
        if abs(slant) > 0.004, abs(slant) < 0.17, let straight = straightened(image, by: slant) {
            let center = CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
            lines = lines.map { $0.turned(by: slant, around: center) }
            image = straight
        }
        guard let ink = Ink(image) else { return lines.map(\.text).joined(separator: "\n") }
        let heights = lines.map(\.box.height).sorted()
        let typical = heights.isEmpty ? CGFloat(ink.height) / 60 : heights[heights.count / 2]
        // A line much taller than the rest is a few taken for one, misread: read again.
        let suspect = lines.count >= 3 ? Set(lines.indices.filter { lines[$0].box.height > typical * 1.8 }) : []
        let covering = lines.indices.filter { !suspect.contains($0) }.map { lines[$0].box }
        let regions = ink.uncovered(by: covering, lineHeight: typical)
        for region in regions.prefix(8) {
            // Not what was read already: a coloured band (a title bar, a chat bubble) is ink around the text in it.
            let read = Self.letters(lines.map(\.text).joined())
            let found = readAgain(region, of: image, ink: ink).filter { !read.contains(Self.letters($0)) }
            guard !found.isEmpty else { continue }
            lines.removeAll { line in line.box.height > typical * 1.8 && line.box.intersects(region.rect) }
            // Before the first line below it that shares its columns.
            let at = lines.firstIndex { $0.box.minY > region.rect.minY && $0.box.minX < region.rect.maxX
                && $0.box.maxX > region.rect.minX } ?? lines.count
            lines.insert(contentsOf: found.map { Line(text: $0, box: region.rect) }, at: at)
        }
        return lines.map(\.text).joined(separator: "\n")
    }

    /// How far its lines slope down to the right (radians), by the long ones; 0 without any.
    static func slant(of lines: [Line], width: CGFloat) -> CGFloat {
        let slopes = lines.filter { $0.corners[1].x - $0.corners[0].x > width / 4 }.map { line in
            atan2(line.corners[1].y - line.corners[0].y, line.corners[1].x - line.corners[0].x)
        }.sorted()
        return slopes.isEmpty ? 0 : slopes[slopes.count / 2]
    }

    /// Turned `angle` anticlockwise about its middle, on white.
    static func straightened(_ image: CGImage, by angle: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: angle)   // drawing is from the bottom up: anticlockwise
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func letters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // .fast reads fewer languages
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            return Line(text: text, corners: corners.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) })
        }
    }

    /// A region's lines, cut apart where the ink thins between them and set one under another with room between, read
    /// again.
    static func readAgain(_ region: Ink.Region, of image: CGImage, ink: Ink) -> [String] {
        fallbacks += 1
        let slices = ink.lines(in: region)
        guard !slices.isEmpty else { return [] }
        let gap = slices.map { $0.upperBound - $0.lowerBound }.max()! / 2 + 8
        let width = Int(region.rect.width) + 2 * gap
        let height = slices.reduce(gap) { $0 + ($1.upperBound - $1.lowerBound) + gap }
        guard height < 12_000, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                                        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.setFillColor(gray: CGFloat(ink.background) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = gap
        for slice in slices {
            let rows = slice.upperBound - slice.lowerBound
            let cut = CGRect(x: Int(region.rect.minX), y: slice.lowerBound, width: Int(region.rect.width), height: rows)
            if let piece = image.cropping(to: cut) {
                // Drawing is from the bottom up.
                context.draw(piece, in: CGRect(x: gap, y: height - top - rows, width: Int(region.rect.width), height: rows))
            }
            top += rows + gap
        }
        guard let spaced = context.makeImage() else { return [] }
        // Bits of letters read as something: at least three letters or digits make a line.
        return recognize(spaced).sorted { $0.box.minY < $1.box.minY }.map(\.text)
            .filter { $0.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count >= 3 }
    }
}

/// Where a picture has ink (what differs from its background), by pixel rows.
struct Ink {
    let width: Int
    let height: Int
    let background: UInt8
    private let dark: [Bool]

    struct Region {
        var rect: CGRect
        var ink: Int
    }

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))   // row 0: the top
        let sample = stride(from: 0, to: pixels.count, by: 7).map { pixels[$0] }.sorted()
        let background = sample[sample.count / 2]
        self.background = background
        dark = pixels.map { abs(Int($0) - Int(background)) > 70 }
    }

    /// Bands with ink no box covers (boxes from the top left), tallest ink first: at least half a line tall, the rows
    /// with ink less than three-fifths of a line apart taken together.
    func uncovered(by boxes: [CGRect], lineHeight: CGFloat) -> [Region] {
        var covered = [Bool](repeating: false, count: width * height)
        for box in boxes {
            let grown = box.insetBy(dx: -4, dy: -box.height * 0.15)
            let x0 = max(0, Int(grown.minX)), x1 = min(width, Int(grown.maxX.rounded(.up)))
            let y0 = max(0, Int(grown.minY)), y1 = min(height, Int(grown.maxY.rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { covered[y * width + x] = true } }
        }
        let least = max(3, width / 300)
        var rows = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where dark[y * width + x] && !covered[y * width + x] { count += 1 }
            rows[y] = count
        }
        var bands: [Range<Int>] = []
        let join = max(2, Int(lineHeight * 0.6))
        for y in 0..<height where rows[y] >= least {
            if let last = bands.last, y - last.upperBound <= join {
                bands[bands.count - 1] = last.lowerBound..<(y + 1)
            } else {
                bands.append(y..<(y + 1))
            }
        }
        return bands.compactMap { band -> Region? in
            guard CGFloat(band.count) >= lineHeight * 0.5 else { return nil }
            var minX = width, maxX = 0, total = 0
            for y in band {
                for x in 0..<width where dark[y * width + x] && !covered[y * width + x] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    total += 1
                }
            }
            guard total >= Int(lineHeight * 4), minX < maxX else { return nil }
            let pad = Int(lineHeight / 2)
            let x0 = max(0, minX - pad), x1 = min(width, maxX + pad)
            return Region(rect: CGRect(x: x0, y: band.lowerBound, width: x1 - x0, height: band.count), ink: total)
        }.sorted { $0.ink > $1.ink }
    }

    /// A region's lines (pixel rows from the top): where its ink is densest (the letters' bodies), with half as much
    /// again above and below (capitals, ascenders and descenders).
    func lines(in region: Region) -> [Range<Int>] {
        let x0 = Int(region.rect.minX), x1 = Int(region.rect.maxX)
        let y0 = Int(region.rect.minY), y1 = Int(region.rect.maxY)
        let profile = (y0..<y1).map { y in (x0..<x1).reduce(0) { $0 + (dark[y * width + $1] ? 1 : 0) } }
        guard let most = profile.max(), most > 0 else { return [] }
        var cores: [Range<Int>] = []
        for (offset, count) in profile.enumerated() where count * 10 >= most * 3 {
            let y = y0 + offset
            if let last = cores.last, y - last.upperBound <= 1 {
                cores[cores.count - 1] = last.lowerBound..<(y + 1)
            } else {
                cores.append(y..<(y + 1))
            }
        }
        // A line's capitals can come apart from its body where the ink thins between them: taken together. Then what's
        // left much shorter than a line is no line (the tips of the letters of the lines around it).
        let typical = cores.map(\.count).sorted()[cores.count / 2]
        var joined: [Range<Int>] = []
        for core in cores {
            if let last = joined.last, core.lowerBound - last.upperBound <= max(2, typical / 3),
               min(core.count, last.count) * 5 < typical * 3 {
                joined[joined.count - 1] = last.lowerBound..<core.upperBound
            } else {
                joined.append(core)
            }
        }
        return joined.filter { $0.count >= 3 && $0.count * 5 >= typical * 2 }.prefix(120).map { core in
            let margin = core.count / 2 + 1
            return max(0, core.lowerBound - margin)..<min(height, core.upperBound + margin)
        }
    }
}
