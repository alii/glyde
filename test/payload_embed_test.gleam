import gleam/http
import gleam/http/request
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import glyde/api/channel
import glyde/id
import glyde/payload/embed
import glyde/payload/message
import glyde/rest
import glyde/rest/body

pub fn empty_embed_sends_nothing_test() {
  assert json.to_string(embed.to_json(embed.new())) == "{}"
}

pub fn setters_chain_test() {
  let built =
    embed.new()
    |> embed.title("glyde")
    |> embed.url("https://github.com/alii/glyde")
    |> embed.description("A sans-IO Discord library for Gleam.")
    |> embed.color(0x5865F2)
    |> embed.author("Alistair")

  assert built.title == Some("glyde")
  assert built.url == Some("https://github.com/alii/glyde")
  assert built.color == Some(0x5865F2)
  assert built.author == Some(embed.EmbedAuthor("Alistair", None, None))
}

pub fn setters_replace_test() {
  let built = embed.new() |> embed.title("first") |> embed.title("second")
  assert built.title == Some("second")
}

/// `field` is the one setter that appends.
pub fn fields_append_test() {
  let built =
    embed.new()
    |> embed.field("Runs on", "Erlang", inline: True)
    |> embed.field("Licence", "Apache-2.0", inline: True)

  assert built.fields
    == [
      embed.EmbedField("Runs on", "Erlang", True),
      embed.EmbedField("Licence", "Apache-2.0", True),
    ]
}

/// The url is the only key of the image object that survives a send.
pub fn image_is_wrapped_in_an_object_test() {
  let encoded = json.to_string(embed.to_json(embed.new() |> embed.image("u")))
  assert encoded == "{\"image\":{\"url\":\"u\"}}"
}

/// Discord's 6000 counts UTF-16 code units, so an emoji is two, and it spans
/// every embed on the message rather than each one on its own.
pub fn character_count_test() {
  let built =
    embed.new()
    |> embed.title("abc")
    |> embed.description("de")
    |> embed.footer("f")
    |> embed.author("gh")
    |> embed.field("ij", "k", inline: False)

  assert embed.character_count([built]) == 11
  assert embed.character_count([embed.new() |> embed.title("🎮")]) == 2
  assert embed.character_count([]) == 0

  // The ten embeds a message may carry are one budget between them.
  assert embed.character_count([built, built]) == 22
  assert embed.total_character_limit == 6000
}

/// A built embed reaches Discord as a real HTTP request.
pub fn an_embed_becomes_a_request_test() {
  let card =
    embed.new()
    |> embed.title("v0.1.0")
    |> embed.description("shipped")
    |> embed.color(0x5865F2)

  let call =
    channel.create_message(
      id.from_string("41771983423143937"),
      message.create_body(
        message.create()
        |> message.content("release")
        |> message.embed(card),
      ),
    )

  let req = rest.request(rest.config(rest.bot("token")), call)

  assert req.method == http.Post
  assert req.host == "discord.com"
  assert req.path == "/api/v10/channels/41771983423143937/messages"
  assert request.get_header(req, "content-type") == Ok("application/json")

  let body = wire_text(req.body)
  assert string.contains(body, "\"content\":\"release\"")
  assert string.contains(body, "\"title\":\"v0.1.0\"")
  assert string.contains(body, "\"color\":5793266")
  assert !string.contains(body, "null")
}

fn wire_text(wire: body.Wire) -> String {
  case wire {
    body.Text(text) -> text
    _ -> ""
  }
}
