import CSQLite
import Foundation

// 数据库对象仅在 LibraryRepository actor 内使用；预编译语句始终绑定参数。
final class SQLiteDatabase {
  private var handle: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(url: URL) throws {
    guard
      sqlite3_open_v2(
        url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      throw LibraryError.message("无法打开书库数据库")
    }
    sqlite3_busy_timeout(handle, 5_000)
    try run("PRAGMA journal_mode=WAL")
    try run("PRAGMA foreign_keys=ON")
    try run(
      "CREATE TABLE IF NOT EXISTS books(id TEXT PRIMARY KEY, folder_id TEXT, hash TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)"
    )
    try run("CREATE INDEX IF NOT EXISTS books_folder ON books(folder_id)")
    try run("CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    try run(
      "CREATE TABLE IF NOT EXISTS annotations(id TEXT PRIMARY KEY, book_id TEXT NOT NULL REFERENCES books(id), payload BLOB NOT NULL)"
    )
    try run("CREATE INDEX IF NOT EXISTS annotations_book ON annotations(book_id)")
    try run("CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    try run("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    try run("PRAGMA user_version=1")
  }
  deinit { sqlite3_close(handle) }
  enum Value {
    case text(String)
    case blob(Data)
    case null
  }

  // SQLITE_TRANSIENT 让 SQLite 拷贝临时 Swift 内存，避免悬垂字符串或数据指针。
  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure()
    }
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      let result: Int32
      switch value {
      case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, transient)
      case .blob(let data):
        result = data.withUnsafeBytes {
          sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient)
        }
      case .null: result = sqlite3_bind_null(statement, position)
      }
      if result != SQLITE_OK {
        sqlite3_finalize(statement)
        throw failure()
      }
    }
    return statement
  }
  func run(_ sql: String, _ values: [Value] = []) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
  }
  func data(_ sql: String, _ values: [Value] = []) throws -> [Data] {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    var rows: [Data] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else { throw failure() }
      let size = Int(sqlite3_column_bytes(statement, 0))
      if let bytes = sqlite3_column_blob(statement, 0) {
        rows.append(Data(bytes: bytes, count: size))
      }
    }
  }

  // 一次逻辑变更采用事务，错误时回滚所有元数据修改。
  func transaction<T>(_ operation: () throws -> T) throws -> T {
    try run("BEGIN IMMEDIATE")
    do {
      let value = try operation()
      try run("COMMIT")
      return value
    } catch {
      try? run("ROLLBACK")
      throw error
    }
  }
  private func failure() -> LibraryError {
    .message("书库数据库错误：\(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知原因")")
  }
}
