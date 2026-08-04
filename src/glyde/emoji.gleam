//// Two shapes. `Emoji` is the partial a button, a select option and a
//// reaction carry; `GuildEmoji` is a guild's own upload, where id and name
//// are always present.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/field.{Null, Present}
import glyde/id
import glyde/user
import glyde/wire

/// The id and the name move together. A unicode emoji is its name and has no
/// id; a custom one is its id and may have lost its name. Discord never sends
/// neither, and only a custom emoji is ever animated.
pub type Emoji {
  Unicode(name: String)

  /// `name` is null in reactions, for a custom emoji deleted since.
  Custom(id: id.EmojiId, name: Option(String), animated: Bool)
}

/// A guild's own emoji, from `Guild.emojis` and GUILD_EMOJIS_UPDATE. Always
/// custom, always named; the roles and uploader are never on a component or a
/// reaction. Use `as_partial` to send one.
pub type GuildEmoji {
  GuildEmoji(
    id: id.EmojiId,
    name: String,
    animated: Bool,
    /// The roles allowed to use it.
    roles: List(id.RoleId),
    /// Who uploaded it. Needs the MANAGE_GUILD_EXPRESSIONS permission.
    uploader: Option(user.User),
    require_colons: Bool,
    managed: Bool,
    /// False when the guild lost the boosts that paid for it.
    available: Bool,
  )
}

/// A standard emoji, named by the character itself.
pub fn unicode(name: String) -> Emoji {
  Unicode(name:)
}

/// The partial that reactions and components take. For an animated one, use
/// `animated_custom`.
pub fn custom(id: id.EmojiId, name: String) -> Emoji {
  Custom(id:, name: Some(name), animated: False)
}

/// A custom emoji whose frames Discord plays.
pub fn animated_custom(id: id.EmojiId, name: String) -> Emoji {
  Custom(id:, name: Some(name), animated: True)
}

pub fn decoder() -> Decoder(Emoji) {
  use emoji_id <- wire.opt_field("id", id.decoder())
  use name <- wire.opt_field("name", decode.string)
  use animated <- wire.flag_field("animated", False)
  decode.success(case emoji_id {
    Some(emoji_id) -> Custom(id: emoji_id, name:, animated:)
    // No id and no name is not a shape Discord sends; read it as the
    // unicode emoji it looks most like rather than failing the payload.
    None -> Unicode(name: option.unwrap(name, ""))
  })
}

/// The id and name are required here. A guild's own list never carries a
/// unicode or a nameless entry, so a payload without them fails to decode.
pub fn guild_emoji_decoder() -> Decoder(GuildEmoji) {
  use id <- decode.field("id", id.decoder())
  use name <- decode.field("name", decode.string)
  use animated <- wire.flag_field("animated", False)
  use roles <- wire.list_field("roles", id.decoder())
  use uploader <- wire.opt_field("user", user.decoder())
  use require_colons <- wire.flag_field("require_colons", False)
  use managed <- wire.flag_field("managed", False)
  use available <- wire.flag_field("available", True)
  decode.success(GuildEmoji(
    id:,
    name:,
    animated:,
    roles:,
    uploader:,
    require_colons:,
    managed:,
    available:,
  ))
}

/// The partial shape for reacting with, or putting on a button.
pub fn as_partial(full: GuildEmoji) -> Emoji {
  Custom(id: full.id, name: Some(full.name), animated: full.animated)
}

/// The partial Discord accepts in a component or a reaction. A null `id` is
/// how it tells a unicode emoji from a custom one, so the key is always there.
pub fn to_json(emoji: Emoji) -> Json {
  let #(emoji_id, name, animated) = case emoji {
    Unicode(name:) -> #(Null, Present(json.string(name)), False)
    Custom(id: emoji_id, name:, animated:) -> #(
      Present(id.to_json(emoji_id)),
      wire.opt(name) |> wire.put(json.string),
      animated,
    )
  }
  wire.object([
    #("id", emoji_id),
    #("name", name),
    #("animated", wire.flag(animated)),
  ])
}
