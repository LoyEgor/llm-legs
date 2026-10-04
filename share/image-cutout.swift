import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ code: Int32, _ message: String) -> Never {
  FileHandle.standardError.write("image-cutout: \(message)\n".data(using: .utf8)!)
  exit(code)
}

var input = "", dest = "", edge = "soft", holes = false, dryRun = false
var keeps: [(Double, Double)] = [], drops: [(Double, Double)] = []
var argv = CommandLine.arguments.dropFirst().makeIterator()
func point(_ text: String?) -> (Double, Double) {
  let parts = (text ?? "").split(separator: ",").compactMap { Double($0) }
  guard parts.count == 2 else { fail(2, "bad point '\(text ?? "")'") }
  return (parts[0], parts[1])
}
while let flag = argv.next() {
  switch flag {
  case "--in": input = argv.next() ?? ""
  case "--dest": dest = argv.next() ?? ""
  case "--keep": keeps.append(point(argv.next()))
  case "--drop": drops.append(point(argv.next()))
  case "--edge": edge = argv.next() ?? ""
  case "--holes": holes = true
  case "--dry-run": dryRun = true
  default: fail(2, "unknown argument \(flag)")
  }
}

let start = Date()
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
else { fail(1, "cannot read \(input)") }
let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
let image: CGImage? =
  orientation == 1
  ? CGImageSourceCreateImageAtIndex(source, 0, nil)
  : CGImageSourceCreateThumbnailAtIndex(
    source, 0,
    [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(
        (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
        (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0),
    ] as CFDictionary)
guard let cg = image else { fail(1, "cannot decode \(input)") }
let width = cg.width, height = cg.height, count = width * height
let space =
  cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!

var pixels = [UInt8](repeating: 0, count: count * 4)
if cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, cg.alphaInfo == .last,
  cg.colorSpace?.model == .rgb, cg.bitmapInfo.intersection(.byteOrderMask).rawValue == 0
    || cg.bitmapInfo.contains(.byteOrder32Big),
  let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
{
  for y in 0..<height {
    memcpy(&pixels[y * width * 4], bytes + y * cg.bytesPerRow, width * 4)
  }
} else {
  // Straight alpha is kept only by the copy above; a drawn translucent source comes back premultiplied.
  let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
  if cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast && cg.alphaInfo != .noneSkipFirst {
    for i in 0..<count where pixels[i * 4 + 3] > 0 && pixels[i * 4 + 3] < 255 {
      let a = Double(pixels[i * 4 + 3])
      for c in 0..<3 {
        pixels[i * 4 + c] = UInt8(min(255, (Double(pixels[i * 4 + c]) * 255 / a).rounded()))
      }
    }
  }
}

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()
do { try handler.perform([request]) } catch { fail(1, "Vision failed: \(error)") }
guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
  fail(1, "Vision found no subject in \(input)")
}

func floats(_ buffer: CVPixelBuffer) -> (width: Int, height: Int, values: [Float]) {
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
  let row = CVPixelBufferGetBytesPerRow(buffer)
  let base = CVPixelBufferGetBaseAddress(buffer)!
  var values = [Float](repeating: 0, count: w * h)
  for y in 0..<h {
    let line = (base + y * row).assumingMemoryBound(to: Float.self)
    for x in 0..<w { values[y * w + x] = line[x] }
  }
  return (w, h, values)
}

let labelBuffer = observation.instanceMask
CVPixelBufferLockBaseAddress(labelBuffer, .readOnly)
let labelWidth = CVPixelBufferGetWidth(labelBuffer), labelHeight = CVPixelBufferGetHeight(labelBuffer)
let labelRow = CVPixelBufferGetBytesPerRow(labelBuffer)
let labelBase = CVPixelBufferGetBaseAddress(labelBuffer)!.assumingMemoryBound(to: UInt8.self)
var labels = (0..<labelWidth * labelHeight).map { Int(labelBase[$0 / labelWidth * labelRow + $0 % labelWidth]) }
CVPixelBufferUnlockBaseAddress(labelBuffer, .readOnly)
func label(_ x: Int, _ y: Int) -> Int { labels[y * labelWidth + x] }

// The whole frame yields only its dominant subjects; a half or quadrant crop also yields the smaller
// objects beside them. A crop's instance counts when it clears the crop's edges (a cut piece of a known
// subject touches one) and lies mostly outside the instances already found.
let firstExtra = observation.allInstances.max()! + 1
var extras: [[Float]] = []
let hx = width / 2, hy = height / 2
for (x0, y0, w, h) in [
  (0, 0, hx, height), (hx, 0, width - hx, height), (0, 0, width, hy), (0, hy, width, height - hy),
  (0, 0, hx, hy), (hx, 0, width - hx, hy), (0, hy, hx, height - hy), (hx, hy, width - hx, height - hy),
] {
  let crop = VNGenerateForegroundInstanceMaskRequest()
  crop.regionOfInterest = CGRect(
    x: Double(x0) / Double(width), y: Double(height - y0 - h) / Double(height),
    width: Double(w) / Double(width), height: Double(h) / Double(height))
  guard (try? handler.perform([crop])) != nil, let found = crop.results?.first else { continue }
  for index in found.allInstances {
    guard let buffer = try? found.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler)
    else { continue }
    let local = floats(buffer)
    guard local.width == w, local.height == h,
      (0..<w).allSatisfy({ local.values[$0] <= 0.5 && local.values[(h - 1) * w + $0] <= 0.5 }),
      (0..<h).allSatisfy({ local.values[$0 * w] <= 0.5 && local.values[$0 * w + w - 1] <= 0.5 })
    else { continue }
    var mask = [Float](repeating: 0, count: count)
    for y in 0..<h {
      for x in 0..<w { mask[(y0 + y) * width + x0 + x] = local.values[y * w + x] }
    }
    let cells = labels.indices.filter {
      mask[
        min(height - 1, ($0 / labelWidth * height + height / 2) / labelHeight) * width
          + min(width - 1, ($0 % labelWidth * width + width / 2) / labelWidth)] > 0.5
    }
    guard !cells.isEmpty, cells.filter({ labels[$0] != 0 }).count * 10 < cells.count else { continue }
    for cell in cells where labels[cell] == 0 { labels[cell] = firstExtra + extras.count }
    extras.append(mask)
  }
}
let instances = observation.allInstances.union(IndexSet(firstExtra..<firstExtra + extras.count))

func instance(at point: (Double, Double)) -> Int {
  let px = min(labelWidth - 1, Int(point.0 * Double(labelWidth)))
  let py = min(labelHeight - 1, Int(point.1 * Double(labelHeight)))
  if label(px, py) != 0 { return label(px, py) }
  var best = 0, bestDistance = Int.max
  for y in 0..<labelHeight {
    for x in 0..<labelWidth where label(x, y) != 0 {
      let distance = (x - px) * (x - px) + (y - py) * (y - py)
      if distance < bestDistance { (best, bestDistance) = (label(x, y), distance) }
    }
  }
  return best
}

var kept = keeps.isEmpty ? instances : IndexSet(keeps.map(instance))
for point in drops { kept.remove(instance(at: point)) }
if dryRun {
  for index in instances {
    var minX = labelWidth, minY = labelHeight, maxX = -1, maxY = -1, area = 0, sumX = 0, sumY = 0
    for y in 0..<labelHeight {
      for x in 0..<labelWidth where label(x, y) == index {
        (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        (area, sumX, sumY) = (area + 1, sumX + x, sumY + y)
      }
    }
    let lw = Double(labelWidth), lh = Double(labelHeight)
    print(
      String(
        format: "instance=%d center=%.3f,%.3f box=%.3f,%.3f,%.3f,%.3f area=%.3f kept=%@", index,
        (Double(sumX) / Double(max(area, 1)) + 0.5) / lw, (Double(sumY) / Double(max(area, 1)) + 0.5) / lh,
        Double(minX) / lw, Double(minY) / lh, Double(maxX - minX + 1) / lw, Double(maxY - minY + 1) / lh,
        Double(area) / (lw * lh), kept.contains(index) ? "yes" : "no"))
  }
}
guard !kept.isEmpty else { fail(1, "the --keep/--drop points leave no instance to keep") }

func scaledMask(_ instances: IndexSet) -> [Float] {
  var mask = [Float](repeating: 0, count: count)
  let whole = instances.filteredIndexSet { $0 < firstExtra }
  if !whole.isEmpty {
    guard let buffer = try? observation.generateScaledMaskForImage(forInstances: whole, from: handler)
    else { fail(1, "Vision could not scale the mask") }
    let scaled = floats(buffer)
    guard scaled.width == width, scaled.height == height else { fail(1, "Vision mask size differs from the image") }
    mask = scaled.values
  }
  for index in instances where index >= firstExtra {
    for i in 0..<count { mask[i] = max(mask[i], extras[index - firstExtra][i]) }
  }
  return mask
}

struct Integral {
  let table: [Double]
  init(_ values: [Double]) {
    var table = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for y in 0..<height {
      var row = 0.0
      for x in 0..<width {
        row += values[y * width + x]
        table[(y + 1) * (width + 1) + x + 1] = table[y * (width + 1) + x + 1] + row
      }
    }
    self.table = table
  }
  func mean(_ x: Int, _ y: Int, _ r: Int) -> (sum: Double, area: Double) {
    let x0 = max(0, x - r), y0 = max(0, y - r), x1 = min(width, x + r + 1), y1 = min(height, y + r + 1)
    let w = width + 1
    let sum = table[y1 * w + x1] - table[y0 * w + x1] - table[y1 * w + x0] + table[y0 * w + x0]
    return (sum, Double((x1 - x0) * (y1 - y0)))
  }
}

// The tent weight keeps the band's borders seamless; without it the re-estimated alpha steps against Vision's.
func refine(_ mask: [Float]) -> [Float] {
  let r = max(3, max(width, height) / 100), wide = 2 * r
  let rgb = (0..<3).map { c in (0..<count).map { Double(pixels[$0 * 4 + c]) / 255 } }
  let hard = Integral(mask.map { $0 > 0.5 ? 1 : 0 })
  let fg = mask.map { $0 > 0.95 ? 1.0 : 0 }, bg = mask.map { $0 < 0.05 ? 1.0 : 0 }
  let fgSum = Integral(fg), bgSum = Integral(bg)
  let fgColor = (0..<3).map { c in Integral((0..<count).map { rgb[c][$0] * fg[$0] }) }
  let bgColor = (0..<3).map { c in Integral((0..<count).map { rgb[c][$0] * bg[$0] }) }
  var out = mask
  for y in 0..<height {
    for x in 0..<width {
      let share = hard.mean(x, y, r)
      let inside = share.sum / share.area
      guard inside > 0, inside < 1 else { continue }
      let nf = fgSum.mean(x, y, wide).sum, nb = bgSum.mean(x, y, wide).sum
      guard nf > 0, nb > 0 else { continue }
      var dot = 0.0, length = 0.0
      for c in 0..<3 {
        let f = fgColor[c].mean(x, y, wide).sum / nf, b = bgColor[c].mean(x, y, wide).sum / nb
        dot += (rgb[c][y * width + x] - b) * (f - b)
        length += (f - b) * (f - b)
      }
      let alpha = min(1, max(0, dot / max(length, 1e-9)))
      let weight = min(1, length.squareRoot() / 0.25) * (1 - abs(2 * inside - 1))
      out[y * width + x] = Float(weight * alpha + (1 - weight) * Double(mask[y * width + x]))
    }
  }
  return out
}

func clearHoles(_ alpha: inout [Float], background: [Float]) {
  let threshold = 30.0
  let samples = (0..<count).filter { background[$0] < 0.05 }
  guard !samples.isEmpty else { return }
  let stride = max(1, samples.count / 20000)
  let points = Swift.stride(from: 0, to: samples.count, by: stride).map { i in
    (0..<3).map { Double(pixels[samples[i] * 4 + $0]) }
  }
  func distance(_ a: [Double], _ b: [Double]) -> Double {
    (0..<3).reduce(0) { $0 + (a[$1] - b[$1]) * (a[$1] - b[$1]) }
  }
  var centres = [(0..<3).map { c in points.reduce(0) { $0 + $1[c] } / Double(points.count) }]
  while centres.count < min(8, points.count) {
    centres.append(points.max { a, b in
      centres.map { distance(a, $0) }.min()! < centres.map { distance(b, $0) }.min()!
    }!)
  }
  for _ in 0..<12 {
    var sums = [[Double]](repeating: [0, 0, 0], count: centres.count)
    var counts = [Int](repeating: 0, count: centres.count)
    for p in points {
      let j = centres.indices.min { distance(p, centres[$0]) < distance(p, centres[$1]) }!
      for c in 0..<3 { sums[j][c] += p[c] }
      counts[j] += 1
    }
    for j in centres.indices where counts[j] > 0 { centres[j] = sums[j].map { $0 / Double(counts[j]) } }
  }
  for i in 0..<count where alpha[i] > 0 {
    let p = (0..<3).map { Double(pixels[i * 4 + $0]) }
    let d = centres.map { distance(p, $0) }.min()!.squareRoot()
    alpha[i] = min(alpha[i], Float(min(1, max(0, (d - threshold) / threshold))))
  }
}

var alpha = scaledMask(kept)
if edge == "soft" { alpha = refine(alpha) }
var holeShare = 0.0
if holes {
  let before = alpha.filter { $0 >= 0.5 }.count
  clearHoles(&alpha, background: scaledMask(instances))
  holeShare = Double(before - alpha.filter { $0 >= 0.5 }.count) / Double(max(before, 1))
}
var transparent = 0
for i in 0..<count {
  let a = edge == "hard" ? (alpha[i] >= 0.5 ? 255 : 0) : Int((alpha[i] * 255).rounded())
  pixels[i * 4 + 3] = UInt8(min(Int(pixels[i * 4 + 3]), max(0, min(255, a))))
  if pixels[i * 4 + 3] < 128 { transparent += 1 }
}

if !dryRun {
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let output = CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
    space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let temporary = URL(fileURLWithPath: dest + ".partial-\(getpid())")
  guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fail(1, "cannot write \(dest)") }
  CGImageDestinationAddImage(destination, output, nil)
  guard CGImageDestinationFinalize(destination), rename(temporary.path, dest) == 0 else {
    try? FileManager.default.removeItem(at: temporary)
    fail(1, "cannot write \(dest)")
  }
}
print(
  String(
    format: "dest=%@ size=%dx%d instances=%d/%d transparent=%.3f%@ seconds=%.2f", dest, width, height,
    kept.count, instances.count, Double(transparent) / Double(count),
    holes ? String(format: " holes=%.3f", holeShare) : "", Date().timeIntervalSince(start)))
