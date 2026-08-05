import gleam/http
import glyde/channel
import glyde/id
import glyde/rest
import glyde/rest/body

/// The DM body is now built inside `channel.open_dm`, so this pins the
/// request rather than a payload constructor.
pub fn open_dm_names_the_recipient_test() {
  let call = channel.open_dm_call(id.from_string("80351110224678912"))
  let req = rest.request(rest.config(rest.bot("t")), call)

  assert req.method == http.Post
  assert req.path == "/api/v10/users/@me/channels"
  let assert body.Text(text) = req.body
  assert text == "{\"recipient_id\":\"80351110224678912\"}"
}

/// Discord takes snowflakes as strings, and this one is past 2^53.
pub fn a_large_recipient_id_keeps_every_digit_test() {
  let call = channel.open_dm_call(id.from_string("1234567890123456789"))
  let assert body.Text(text) =
    rest.request(rest.config(rest.bot("t")), call).body
  assert text == "{\"recipient_id\":\"1234567890123456789\"}"
}
