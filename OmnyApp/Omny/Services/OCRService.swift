import Foundation
import Vision
import UIKit

/// Vision OCR：图片 → 文本。系统能力，免费、本地。
enum OCRService {
    static func recognizeText(in imageData: Data) async throws -> String {
        guard let image = UIImage(data: imageData)?.cgImage else {
            throw OCRError.invalidImage
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum OCRError: Error {
        case invalidImage
    }
}
