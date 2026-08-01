//// Answering an interaction, and everything after the answer.
////
//// Every route here takes a `Responder`, which holds the two ids and the
//// token as one value: the token in the path is the credential, so these
//// calls go out with no `Authorization` header whatever the `rest.Config`
//// holds, and a 401 is about that path token (`error.invalid_webhook_token`,
//// which `error.is_path_token_dead` answers True for), never about the bot
//// token. An expired interaction is not a 401: it is one of the codes below.
////
//// The follow-up routes are `api/webhook`'s with `thread: None` wired in.
//// Discord does not accept `thread_id` on an interaction follow-up, and the
//// token already says which channel the message lands in.
////
//// Deadlines, which glyde has no clock to enforce:
////
//// | Deadline | Value | Miss it and |
//// |---|---|---|
//// | first response | 3 seconds | the token dies, later calls are `10062` |
//// | token lifetime | 15 minutes | follow-ups are `10015` |
//// | responding twice | any time | `40060` |
////
//// A follow-up straight after a deferred response edits the original instead:
//// no message is created and the ephemeral flag is ignored. Discord calls
//// that deprecated, so use `edit_original_response`.

import gleam/option.{None}
import glyde/api/webhook
import glyde/id

// Unqualified, so the module name is out of scope: `interaction` is the
// natural name for a value here, and the two would collide in one expression.
import glyde/model/interaction.{
  type Interaction, type InteractionCallbackResponse, type InteractionToken,
  callback_response_decoder, reveal_token,
} as _
import glyde/model/message.{type Message}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg

/// Who to answer. One value, because the ids and the token have to come from
/// the same interaction: the `Id` tags catch an id swapped for an id, and this
/// catches the token of the other interaction in flight.
pub opaque type Responder {
  Responder(
    interaction: id.InteractionId,
    application: id.ApplicationId,
    token: InteractionToken,
  )
}

/// The gateway path. Everything comes off the one INTERACTION_CREATE, so the
/// three cannot disagree.
pub fn responding_to(interaction: Interaction) -> Responder {
  Responder(
    interaction: interaction.id,
    application: interaction.application_id,
    token: interaction.token,
  )
}

/// The HTTP-interactions path, and a token kept somewhere across a restart.
/// Prefer `responding_to` where there is an `Interaction` to hand.
pub fn responder(
  interaction interaction: id.InteractionId,
  application application: id.ApplicationId,
  token token: InteractionToken,
) -> Responder {
  Responder(interaction:, application:, token:)
}

/// `POST /interactions/{interaction.id}/{token}/callback`, the first answer.
/// Answers 204: use `callback_with_response` if you need the message id.
pub fn callback(responder: Responder, body: Body) -> Call(Nil) {
  rest.post(callback_at(responder), body, rest.NoContent(Nil))
  |> rest.path_authenticated
}

/// `POST /interactions/{interaction.id}/{token}/callback?with_response=true`,
/// answering 200 with the callback resource instead of 204.
pub fn callback_with_response(
  responder: Responder,
  body: Body,
) -> Call(InteractionCallbackResponse) {
  rest.post(
    callback_at(responder),
    body,
    rest.Decoded(callback_response_decoder()),
  )
  |> rest.path_authenticated
  |> rest.query(query.one("with_response", query.flag(True)))
}

/// `GET /webhooks/{application.id}/{token}/messages/@original`.
pub fn get_original_response(responder: Responder) -> Call(Message) {
  webhook.get_original_message(as_webhook(responder), thread: None)
}

/// `PATCH /webhooks/{application.id}/{token}/messages/@original`. Turns a
/// deferred response into a real one, and edits one already sent.
pub fn edit_original_response(
  responder: Responder,
  body: Body,
) -> Call(Message) {
  webhook.edit_original_message(as_webhook(responder), body, thread: None)
}

/// `DELETE /webhooks/{application.id}/{token}/messages/@original`, which
/// works on an ephemeral response as well.
pub fn delete_original_response(responder: Responder) -> Call(Nil) {
  webhook.delete_original_message(as_webhook(responder), thread: None)
}

/// `POST /webhooks/{application.id}/{token}?wait=true`, an extra message on
/// the same interaction. Capped at five when the app is user-installed and not
/// a member of the server, `40094` past that.
pub fn create_followup(responder: Responder, body: Body) -> Call(Message) {
  webhook.execute_and_wait(as_webhook(responder), body, thread: None)
}

/// `GET /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn get_followup(
  responder: Responder,
  message: id.MessageId,
) -> Call(Message) {
  webhook.get_message(as_webhook(responder), message, thread: None)
}

/// `PATCH /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn edit_followup(
  responder: Responder,
  message: id.MessageId,
  body: Body,
) -> Call(Message) {
  webhook.edit_message(as_webhook(responder), message, body, thread: None)
}

/// `DELETE /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn delete_followup(
  responder: Responder,
  message: id.MessageId,
) -> Call(Nil) {
  webhook.delete_message(as_webhook(responder), message, thread: None)
}

/// This route is `route.Unbound`: it sits in no bucket, so the token cannot
/// reach a key however the path is written. `opaque_text` keeps it out of the
/// template as well, which is what a log of the route would show.
fn callback_at(responder: Responder) -> List(seg.Seg) {
  [
    seg.lit("interactions"),
    seg.id(responder.interaction),
    seg.opaque_text(reveal_token(responder.token)),
    seg.lit("callback"),
  ]
}

/// Follow-ups are the webhook routes with the application id in the webhook
/// id's place, which is Discord's own spelling of them.
fn as_webhook(responder: Responder) -> webhook.Credential {
  webhook.application_credential(
    responder.application,
    reveal_token(responder.token),
  )
}
