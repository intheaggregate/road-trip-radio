import Foundation
import Vision

let image = URL(fileURLWithPath:CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(url:image,options:[:]).perform([request])
let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let compact = words.joined().lowercased().filter(\.isLetter)
guard compact.contains("connectspotify"),
      compact.contains("roadtripradio") || compact.contains("planadrive") else {
    print("Drive screen not visible. Recognized text: " + words.joined(separator:" | "))
    exit(1)
}
print("Verified the Drive screen and Spotify connection button.")
