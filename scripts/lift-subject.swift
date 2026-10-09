// lift-subject <in.png> <out.png>
//
// The subject of an illustration on transparency, by Vision's foreground
// instance mask — the same lift as "Copy Subject" in Photos. Used by
// make-character-skin.py --cutout for sheets whose cells have a dark ground
// that would sit on a light theme as a dark square. Runs locally; nothing is
// uploaded anywhere.
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: lift-subject <in.png> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cg)
do {
    try handler.perform([request])
    guard let result = request.results?.first else {
        FileHandle.standardError.write("no subject found in \(args[1])\n".data(using: .utf8)!)
        exit(3)
    }
    // Same canvas as the cell (not cropped), so every cell keeps its framing.
    let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                croppedToInstancesExtent: false)
    let ci = CIImage(cvPixelBuffer: buffer)
    guard let out = CIContext().createCGImage(ci, from: ci.extent),
          let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { exit(4) }
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
