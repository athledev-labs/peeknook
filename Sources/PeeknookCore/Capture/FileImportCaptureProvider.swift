// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics
import ImageIO

/// The file-import arm of a capture provider: turn a user-picked file URL into a vision `CaptureResult`.
/// Kept OFF `CaptureProviding.capture(scope:quick:encoding:)` because a file import carries a URL the
/// scope/quick capture path has no slot for (mirrors how the camera's live-preview needs live OUTSIDE
/// the capture seam via `CameraSessionControlling`). The open panel itself lives in the UI layer, so
/// this stays a pure, headless-testable decode with no AppKit dependency.
public protocol FileImporting: Sendable {
    func captureResult(fromFileAt url: URL, encoding: CaptureEncodingParams) async throws -> CaptureResult
}

/// File-import ground provider: load a PDF's first page or an image file from disk and run it through
/// the SAME `CaptureImageEncoder` (and long-edge cap) the screen and camera grounds use, so an imported
/// page reaches the model on equal footing with a screenshot. Needs no TCC permission — the open panel
/// grants file access — so `Ground.file.requiredPermissions` is empty and the flow skips the readiness gate.
public struct FileImportCaptureProvider: CaptureProviding, FileImporting, Sendable {
    public init() {}

    /// Registry arm — unreachable in the shipped flow: file import always goes through
    /// ``captureResult(fromFileAt:encoding:)`` with a user-picked URL, and no profile resolves its
    /// `primaryGround` to `.file`. A scope/quick capture has no file to read.
    public func capture(scope: CaptureScope, quick: Bool, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        _ = (scope, quick, encoding)
        throw CaptureError.noContent
    }

    public func captureResult(fromFileAt url: URL, encoding: CaptureEncodingParams) async throws -> CaptureResult {
        try Self.makeResult(fromFileAt: url, encoding: encoding)
    }

    /// Pure decode (the testable core): file URL → `CGImage` → encoded vision `CaptureResult`. The
    /// filename rides in `appName` so the preview/prompt trust line reads "Report.pdf" (a file has no
    /// owning app/window, and the typed `ground` keeps the label honest — see `CaptureResult.targetLabel`).
    static func makeResult(fromFileAt url: URL, encoding: CaptureEncodingParams) throws -> CaptureResult {
        let image = try loadCGImage(fromFileAt: url)
        guard let base64 = CaptureImageEncoder.jpegBase64(
            from: image, maxPixel: encoding.maxPixel, quality: encoding.jpegQuality
        ) else {
            throw CaptureError.failed("Couldn't read “\(url.lastPathComponent)” as an image.")
        }
        return CaptureResult(
            text: nil,
            sourceLabel: "Imported file",
            appName: url.lastPathComponent,
            screenshotBase64: base64,
            ground: .file
        )
    }

    static func loadCGImage(fromFileAt url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "pdf" {
            return try firstPDFPageImage(at: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.failed("Couldn't open “\(url.lastPathComponent)”. Use a PNG, JPEG, HEIC, or PDF.")
        }
        return image
    }

    /// Render page 1 onto a white bitmap. Capped at a 2000px long edge so a poster-size page doesn't
    /// allocate a huge bitmap before `CaptureImageEncoder` downsizes it to the vision payload.
    static func firstPDFPageImage(at url: URL) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
            throw CaptureError.failed("Couldn't open the PDF “\(url.lastPathComponent)”.")
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else {
            throw CaptureError.failed("The PDF “\(url.lastPathComponent)” has no readable first page.")
        }
        let maxRenderEdge: CGFloat = 2000
        let scale = min(1, maxRenderEdge / max(mediaBox.width, mediaBox.height))
        let width = max(1, Int((mediaBox.width * scale).rounded()))
        let height = max(1, Int((mediaBox.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CaptureError.failed("Couldn't render the PDF “\(url.lastPathComponent)”.")
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let renderRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: renderRect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw CaptureError.failed("Couldn't render the PDF “\(url.lastPathComponent)”.")
        }
        return image
    }
}
