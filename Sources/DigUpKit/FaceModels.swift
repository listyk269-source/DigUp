import Foundation

/// OpenCV Zoo weights at one immutable revision. They are downloaded only after an explicit face-index request.
public enum FaceModels {
    public static let revision = "47534e27c9851bb1128ccc0102f1145e27f23f98"
    public static let modelID = "yunet-2023mar-sface-2021dec-rgbraw-align112-v1"
    public static let all = [
        ModelFiles.File(name: "face_detection_yunet_2023mar.onnx", bytes: 232589,
                        sha256: "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
                        url: URL(string: "https://media.githubusercontent.com/media/opencv/opencv_zoo/\(revision)/models/face_detection_yunet/face_detection_yunet_2023mar.onnx")!),
        ModelFiles.File(name: "face_recognition_sface_2021dec.onnx", bytes: 38696353,
                        sha256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
                        url: URL(string: "https://media.githubusercontent.com/media/opencv/opencv_zoo/\(revision)/models/face_recognition_sface/face_recognition_sface_2021dec.onnx")!)
    ]
    public static var installed: URL {
        if let path = ProcessInfo.processInfo.environment["DIGUP_MODELS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return ModelFiles.installed
    }
    public static func complete(in folder: URL) -> Bool { all.allSatisfy { ModelFiles.isComplete($0, in: folder) } }
}
