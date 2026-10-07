import CoreVideo
import Foundation
import Vision

/// What one camera sees of your face on a single analysis pass.
struct FaceReading {
    /// Face bounds in Vision's normalized coordinates (origin bottom-left).
    var boundingBox: CGRect
    var imageSize: CGSize
    /// Signed head turn relative to this camera. 0 = facing it head on.
    var headTurn: Double
    /// Signed pupil offset inside the eye. 0 = eyes centered.
    var eyeTurn: Double?
    /// Vision's own yaw estimate in degrees, for display only.
    var yawDegrees: Double?
    /// +1 if the measured turn axis points toward image +x, else -1. Used to draw the gaze hint.
    var axisSign: Double

    /// How far your gaze is from this camera. Lower = looking more directly at it.
    func offAxis(eyeWeight: Double) -> Double {
        let landmarkOffAxis = abs(gaze(eyeWeight: eyeWeight))
        // Landmarks get unreliable near profile; Vision's yaw doesn't, so it sets a floor.
        guard let yawDegrees else { return landmarkOffAxis }
        return max(landmarkOffAxis, abs(yawDegrees) * .pi / 180 * 0.4)
    }

    /// Signed combined gaze, in image +x direction.
    func gaze(eyeWeight: Double) -> Double {
        (headTurn + eyeWeight * (eyeTurn ?? 0)) * axisSign
    }
}

/// Estimates how directly a face is pointed at the camera from Vision face landmarks.
///
/// The camera you are looking at sees your face head-on: the nose sits midway between the
/// eyes and midway across the face outline. Cameras off to the side see the nose shifted
/// toward one edge. Comparing that offset across cameras picks the one you're facing.
final class FaceAnalyzer {
    private let rectanglesRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    init() {
        rectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) -> FaceReading? {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([rectanglesRequest])
        } catch {
            return nil
        }
        // The largest face is the person sitting at the desk.
        guard let face = rectanglesRequest.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else {
            return nil
        }
        let yaw = face.yaw?.doubleValue

        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest])
        let landmarks = landmarksRequest.results?.first?.landmarks

        var reading = FaceReading(
            boundingBox: face.boundingBox,
            imageSize: imageSize,
            headTurn: 0,
            eyeTurn: nil,
            yawDegrees: yaw.map { $0 * 180 / .pi },
            axisSign: 1
        )

        guard let landmarks,
              let leftEye = points(landmarks.leftEye, imageSize),
              let rightEye = points(landmarks.rightEye, imageSize),
              let nosePoints = points(landmarks.nose, imageSize) ?? points(landmarks.noseCrest, imageSize)
        else {
            // No landmarks: fall back to Vision's coarse yaw.
            guard let yaw else { return nil }
            reading.headTurn = yaw * 0.6
            return reading
        }

        let leftCenter = centroid(leftEye)
        let rightCenter = centroid(rightEye)
        let axis = rightCenter - leftCenter
        let axisLengthSquared = axis.dot(axis)
        guard axisLengthSquared > 1 else { return nil }
        let axisLength = axisLengthSquared.squareRoot()
        let unitAxis = CGPoint(x: axis.x / axisLength, y: axis.y / axisLength)
        let nose = centroid(nosePoints)
        reading.axisSign = axis.x >= 0 ? 1 : -1

        // Nose position relative to the midpoint between the eyes.
        let eyeMid = CGPoint(x: (leftCenter.x + rightCenter.x) / 2, y: (leftCenter.y + rightCenter.y) / 2)
        var turns = [Double((nose - eyeMid).dot(axis) / axisLengthSquared)]

        // Nose position relative to the face outline's two edges.
        if let contour = points(landmarks.faceContour, imageSize), let first = contour.first, let last = contour.last {
            let a = first.dot(unitAxis)
            let b = last.dot(unitAxis)
            let width = abs(b - a)
            if width > 1 {
                turns.append(Double((nose.dot(unitAxis) - (a + b) / 2) / width))
            }
        }
        reading.headTurn = turns.reduce(0, +) / Double(turns.count)

        // Pupil position within each eye.
        if let leftPupil = points(landmarks.leftPupil, imageSize)?.first,
           let rightPupil = points(landmarks.rightPupil, imageSize)?.first,
           let leftOffset = pupilOffset(leftPupil, eye: leftEye, axis: unitAxis),
           let rightOffset = pupilOffset(rightPupil, eye: rightEye, axis: unitAxis) {
            reading.eyeTurn = (leftOffset + rightOffset) / 2
        }

        return reading
    }

    private func pupilOffset(_ pupil: CGPoint, eye: [CGPoint], axis: CGPoint) -> Double? {
        let projections = eye.map { $0.dot(axis) }
        guard let low = projections.min(), let high = projections.max(), high - low > 1 else { return nil }
        return Double((pupil.dot(axis) - (low + high) / 2) / (high - low))
    }

    private func points(_ region: VNFaceLandmarkRegion2D?, _ imageSize: CGSize) -> [CGPoint]? {
        guard let region, region.pointCount > 0 else { return nil }
        return region.pointsInImage(imageSize: imageSize)
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
}
