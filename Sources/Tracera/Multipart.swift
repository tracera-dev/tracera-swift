import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Frames a blob as single-part `multipart/form-data` with a known length.
///
/// Path blobs stream via an `InputStream` (no second full-size temp copy —
/// Dart/Go `openMultipart` parity). In-memory blobs stay in a single `Data` body.
package struct MultipartBody: Sendable {
  package enum Source: @unchecked Sendable {
    case data(Data)
    case stream(InputStream)
  }

  package var contentType: String
  package var length: Int
  package var source: Source
}

package func openMultipart(fileName: String, mimeType: String, path: String?, data: Data?) throws -> MultipartBody {
  let boundary = "tracera-\(UUID().uuidString)"
  let safeName = fileName
    .replacingOccurrences(of: "\r", with: "")
    .replacingOccurrences(of: "\n", with: "")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let head = Data(
    (
      "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        + "Content-Type: \(mimeType)\r\n"
        + "\r\n"
    ).utf8
  )
  let tail = Data("\r\n--\(boundary)--\r\n".utf8)
  let contentType = "multipart/form-data; boundary=\(boundary)"

  if let path, !path.isEmpty {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [
        NSLocalizedDescriptionKey: "ENOENT: \(path)",
      ])
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let fileLength = (attrs[.size] as? NSNumber)?.intValue ?? 0
    let total = head.count + fileLength + tail.count
    let stream = MultipartReadStream(head: head, filePath: path, fileLength: fileLength, tail: tail)
    return MultipartBody(contentType: contentType, length: total, source: .stream(stream))
  }

  var body = head
  body.append(data ?? Data())
  body.append(tail)
  return MultipartBody(contentType: contentType, length: body.count, source: .data(body))
}

/// Concatenates head + on-disk file (bounded length) + tail without buffering
/// the artifact or writing a second copy.
private final class MultipartReadStream: InputStream {
  private enum Phase {
    case head
    case file
    case tail
    case done
  }

  private let head: Data
  private var headOffset = 0
  private let filePath: String
  private var fileRemaining: Int
  private var fileHandle: FileHandle?
  private let tail: Data
  private var tailOffset = 0
  private var phase: Phase = .head
  private var status: Status = .notOpen
  private var error: Error?
  private weak var _delegate: StreamDelegate?

  init(head: Data, filePath: String, fileLength: Int, tail: Data) {
    self.head = head
    self.filePath = filePath
    self.fileRemaining = fileLength
    self.tail = tail
    super.init(data: Data())
  }

  override var streamStatus: Status { status }
  override var streamError: Error? { error }
  override var delegate: StreamDelegate? {
    get { _delegate }
    set { _delegate = newValue }
  }

  override var hasBytesAvailable: Bool {
    status == .open && phase != .done
  }

  override func open() {
    guard status == .notOpen else { return }
    do {
      fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
      status = .open
    } catch {
      self.error = error
      status = .error
    }
  }

  override func close() {
    try? fileHandle?.close()
    fileHandle = nil
    status = .closed
    phase = .done
  }

  override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
    guard status == .open, len > 0 else { return 0 }
    var written = 0
    while written < len {
      switch phase {
      case .head:
        let n = min(len - written, head.count - headOffset)
        if n > 0 {
          head.copyBytes(to: buffer + written, from: headOffset..<(headOffset + n))
          headOffset += n
          written += n
        }
        if headOffset >= head.count { phase = fileRemaining > 0 ? .file : .tail }
      case .file:
        let want = min(len - written, fileRemaining)
        guard want > 0, let handle = fileHandle else {
          phase = .tail
          continue
        }
        do {
          let chunk = try handle.read(upToCount: want) ?? Data()
          if chunk.isEmpty {
            phase = .tail
            continue
          }
          chunk.copyBytes(to: buffer + written, count: chunk.count)
          written += chunk.count
          fileRemaining -= chunk.count
          if fileRemaining <= 0 { phase = .tail }
        } catch {
          self.error = error
          status = .error
          return -1
        }
      case .tail:
        let n = min(len - written, tail.count - tailOffset)
        if n > 0 {
          tail.copyBytes(to: buffer + written, from: tailOffset..<(tailOffset + n))
          tailOffset += n
          written += n
        }
        if tailOffset >= tail.count {
          phase = .done
          status = .atEnd
        }
      case .done:
        return written
      }
    }
    return written
  }

  override func getBuffer(
    _: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    length _: UnsafeMutablePointer<Int>
  ) -> Bool {
    false
  }

  override func schedule(in _: RunLoop, forMode _: RunLoop.Mode) {}
  override func remove(from _: RunLoop, forMode _: RunLoop.Mode) {}
  override func property(forKey _: PropertyKey) -> Any? { nil }
  override func setProperty(_: Any?, forKey _: PropertyKey) -> Bool { false }
}
