import gleam/json
import glyde/id
import glyde/payload/user
import glyde/rest/body

/// What these tests pin is the JSON document the body carries.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

pub fn create_dm_names_the_recipient_test() {
  let dm = user.CreateDm(recipient_id: id.from_string("80351110224678912"))

  assert payload_json(user.create_dm_body(dm))
    == "{\"recipient_id\":\"80351110224678912\"}"
}

/// Discord takes snowflakes as strings, and this one is past 2^53.
pub fn a_large_recipient_id_keeps_every_digit_test() {
  let dm = user.CreateDm(recipient_id: id.from_string("1234567890123456789"))

  assert payload_json(user.create_dm_body(dm))
    == "{\"recipient_id\":\"1234567890123456789\"}"
}
