//// Bot token for the gateway. Opaque with a closure body so `string.inspect`
//// and `echo` cannot print it, matching `rest.Token`.

pub opaque type Token {
  Token(reveal: fn() -> String)
}

pub fn new(secret: String) -> Token {
  Token(fn() { secret })
}

@internal
pub fn reveal(token: Token) -> String {
  token.reveal()
}
