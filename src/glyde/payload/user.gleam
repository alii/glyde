//// Bodies for the endpoints under `/users`.

import glyde/id
import glyde/rest/body.{type Body}

/// `POST /users/@me/channels`.
pub type CreateDm {
  CreateDm(recipient_id: id.UserId)
}

pub fn create_dm_body(payload: CreateDm) -> Body {
  body.json([#("recipient_id", id.to_json(payload.recipient_id))])
}
