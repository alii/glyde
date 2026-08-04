//// A close code a client may put on the wire: 1000, or 3000 to 4999. Opaque
//// so a socket cannot be closed with one RFC 6455 forbids.

pub opaque type SendCode {
  SendCode(number: Int)
}

/// 1000, normal closure.
pub const shutdown: SendCode = SendCode(1000)

/// 4000, the start of the application range.
pub const resume: SendCode = SendCode(4000)

/// The `Error` hands the number back.
pub fn new(number: Int) -> Result(SendCode, Int) {
  case number == 1000 || { number >= 3000 && number <= 4999 } {
    True -> Ok(SendCode(number))
    False -> Error(number)
  }
}

pub fn to_int(code: SendCode) -> Int {
  code.number
}
