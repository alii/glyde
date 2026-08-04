//// A webhook's id and token together are one major parameter, so two webhooks
//// never share a bucket. They are one credential too, which is why they come
//// in here as a single `Credential`. That credential is in the path, so these
//// calls send no `Authorization` header whatever the `rest.Config` holds: a
//// 401 means the webhook was deleted or its token rotated, never that the bot
//// token is bad. `error.is_path_token_dead` is the predicate for that, and
//// `error.is_token_fatal` answers False for it.
////
//// `glyde/interaction` is these same seven routes with the application id
//// and the interaction token in place of the webhook's.
////
//// `thread` means two things. On `execute` and `execute_and_wait` it is the
//// thread to post into; on the six message routes it says which thread the
//// target message is in. Either way the thread must be on the webhook's
//// channel: Discord ignores it off a text channel, and answers 404 for a
//// thread anywhere else.

import gleam/list
import gleam/option.{type Option}
import glyde/id
import glyde/message.{type Message}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg

/// A webhook's id and its token. One value, so the id of one webhook cannot
/// go out with the token of another. A closure, not a field, because `echo`
/// and `string.inspect` read straight through an opaque record.
pub opaque type Credential {
  Credential(webhook: id.WebhookId, reveal: fn() -> String)
}

pub fn credential(webhook_id: id.WebhookId, token: String) -> Credential {
  Credential(webhook: webhook_id, reveal: fn() { token })
}

/// Interaction follow-ups are these routes with the application id where the
/// webhook id belongs. That is Discord's own spelling, so the retag lives
/// here rather than at each call site.
pub fn application_credential(
  application: id.ApplicationId,
  token: String,
) -> Credential {
  credential(id.retag(application, to: id.webhook), token)
}

/// `POST /webhooks/{webhook.id}/{webhook.token}`. Answers 204 with no body:
/// use `execute_and_wait` to get the message back.
pub fn execute(
  credential: Credential,
  body: Body,
  thread thread: Option(id.ChannelId),
) -> Call(Nil) {
  rest.post(webhook_at(credential), body, rest.NoContent(Nil))
  |> rest.query(thread_param(thread))
}

/// `POST /webhooks/{webhook.id}/{webhook.token}?wait=true`, which answers 200
/// with the message instead of 204 with nothing.
pub fn execute_and_wait(
  credential: Credential,
  body: Body,
  thread thread: Option(id.ChannelId),
) -> Call(Message) {
  rest.post(webhook_at(credential), body, rest.Decoded(message.decoder()))
  |> rest.query(
    list.flatten([query.one("wait", True, query.flag), thread_param(thread)]),
  )
}

pub fn get_original_message(
  credential: Credential,
  thread thread: Option(id.ChannelId),
) -> Call(Message) {
  rest.get(original_at(credential), rest.Decoded(message.decoder()))
  |> rest.query(thread_param(thread))
}

/// `PATCH /webhooks/{webhook.id}/{webhook.token}/messages/@original`. An
/// `attachments` array is the complete list of files to keep.
pub fn edit_original_message(
  credential: Credential,
  body: Body,
  thread thread: Option(id.ChannelId),
) -> Call(Message) {
  rest.patch(original_at(credential), body, rest.Decoded(message.decoder()))
  |> rest.query(thread_param(thread))
}

pub fn delete_original_message(
  credential: Credential,
  thread thread: Option(id.ChannelId),
) -> Call(Nil) {
  rest.delete(original_at(credential), rest.NoContent(Nil))
  |> rest.query(thread_param(thread))
}

pub fn get_message(
  credential: Credential,
  message: id.MessageId,
  thread thread: Option(id.ChannelId),
) -> Call(Message) {
  rest.get(message_at(credential, message), rest.Decoded(message.decoder()))
  |> rest.query(thread_param(thread))
}

pub fn edit_message(
  credential: Credential,
  message: id.MessageId,
  body: Body,
  thread thread: Option(id.ChannelId),
) -> Call(Message) {
  rest.patch(
    message_at(credential, message),
    body,
    rest.Decoded(message.decoder()),
  )
  |> rest.query(thread_param(thread))
}

pub fn delete_message(
  credential: Credential,
  message: id.MessageId,
  thread thread: Option(id.ChannelId),
) -> Call(Nil) {
  rest.delete(message_at(credential, message), rest.NoContent(Nil))
  |> rest.query(thread_param(thread))
}

fn thread_param(thread: Option(id.ChannelId)) -> List(query.Param) {
  query.opt("thread_id", thread, query.snowflake)
}

/// Both halves go in as one segment, written as placeholders in the template.
/// The token is still half the bucket key, deliberately: two webhooks on one
/// channel have separate limits. The limiter drops idle buckets on a `Tick`.
fn webhook_at(credential: Credential) -> List(seg.Seg) {
  [seg.lit("webhooks"), seg.webhook(credential.webhook, credential.reveal())]
}

fn original_at(credential: Credential) -> List(seg.Seg) {
  list.append(webhook_at(credential), [
    seg.lit("messages"),
    seg.lit("@original"),
  ])
}

fn message_at(credential: Credential, message: id.MessageId) -> List(seg.Seg) {
  list.append(webhook_at(credential), [seg.lit("messages"), seg.id(message)])
}
