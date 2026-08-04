//// Two records. `Emoji` is the partial a button, a select option and a
//// reaction carry; `GuildEmoji` is that plus the fields only a guild's own
//// emoji has.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/user
import glyde/wire

/// What every emoji payload carries, full or partial.
pub type Emoji {
  Emoji(kind: Kind, animated: Bool)
}

/// A guild's own emoji, from `Guild.emojis` and GUILD_EMOJIS_UPDATE. Nothing
/// below `emoji` is ever sent on a component or a reaction.
pub type GuildEmoji {
  GuildEmoji(
    emoji: Emoji,
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

/// The id and the name move together. A unicode emoji is its name and has no
/// id; a custom one is its id and may have lost its name. Discord never sends
/// neither, which is the state this collapse removes.
pub type Kind {
  Unicode(name: String)

  /// `name` is null in reactions, for a custom emoji deleted since.
  Custom(id: id.EmojiId, name: Option(String))
}

/// A standard emoji, named by the character itself.
pub fn unicode(name: String) -> Emoji {
  Emoji(kind: Unicode(name:), animated: False)
}

/// The partial that reactions and components take. For an animated one:
/// `Emoji(..custom(id, name), animated: True)`.
pub fn custom(id: id.EmojiId, name: String) -> Emoji {
  Emoji(kind: Custom(id:, name: Some(name)), animated: False)
}

pub fn decoder() -> Decoder(Emoji) {
  use emoji_id <- wire.opt_field("id", id.decoder())
  use name <- wire.opt_field("name", decode.string)
  use animated <- wire.flag_field("animated", False)
  decode.success(Emoji(
    kind: case emoji_id {
      Some(emoji_id) -> Custom(id: emoji_id, name:)
      // No id and no name is not a shape Discord sends; read it as the
      // unicode emoji it looks most like rather than failing the payload.
      None -> Unicode(name: option.unwrap(name, ""))
    },
    animated:,
  ))
}

/// The guild fields sit beside the partial's, not nested under a key.
pub fn guild_emoji_decoder() -> Decoder(GuildEmoji) {
  use emoji <- decode.then(decoder())
  use roles <- wire.list_field("roles", id.decoder())
  use uploader <- wire.opt_field("user", user.decoder())
  use require_colons <- wire.flag_field("require_colons", False)
  use managed <- wire.flag_field("managed", False)
  use available <- wire.flag_field("available", True)
  decode.success(GuildEmoji(
    emoji:,
    roles:,
    uploader:,
    require_colons:,
    managed:,
    available:,
  ))
}

/// The partial Discord accepts in a component or a reaction. A null `id` is
/// how it tells a unicode emoji from a custom one, so the key is always there.
pub fn to_json(emoji: Emoji) -> Json {
  let #(emoji_id, name) = case emoji.kind {
    Unicode(name:) -> #(wire.null(), wire.present(json.string(name)))
    Custom(id: emoji_id, name:) -> #(
      wire.present(id.to_json(emoji_id)),
      wire.opt(name) |> wire.put(json.string),
    )
  }
  wire.object([
    #("id", emoji_id),
    #("name", name),
    #("animated", wire.flag(emoji.animated)),
  ])
}
