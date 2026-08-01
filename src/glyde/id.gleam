//// Discord IDs, called snowflakes. Always a String: Discord sends them as
//// JSON strings and nothing ever does arithmetic on one.
////
//// Each is tagged with what it identifies, so swapping the two snowflakes in
//// `/channels/{channel_id}/messages/{message_id}` will not compile.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/order.{type Order}
import gleam/string

pub opaque type Id(kind) {
  Id(text: String)
}

// Tags with no values, used only to index `Id`. Use the aliases below.

pub type Application

pub type Attachment

pub type Channel

/// An application command, called a slash command in the UI.
pub type Command

pub type Emoji

/// A guild integration, such as a linked Twitch or YouTube account.
pub type Integration

pub type Guild

pub type Interaction

pub type Message

/// A permission overwrite, which is addressed by the id of the role or member
/// it applies to. `model/channel.OverwriteTarget` says which of the two.
pub type Overwrite

pub type Role

pub type ScheduledEvent

/// A monetisation SKU.
pub type Sku

pub type Sticker

/// A subscription listing, used by role subscriptions.
pub type SubscriptionListing

pub type User

pub type Webhook

pub type ApplicationId =
  Id(Application)

pub type AttachmentId =
  Id(Attachment)

pub type ChannelId =
  Id(Channel)

pub type CommandId =
  Id(Command)

pub type EmojiId =
  Id(Emoji)

pub type GuildId =
  Id(Guild)

pub type IntegrationId =
  Id(Integration)

pub type InteractionId =
  Id(Interaction)

pub type MessageId =
  Id(Message)

pub type OverwriteId =
  Id(Overwrite)

pub type RoleId =
  Id(Role)

pub type ScheduledEventId =
  Id(ScheduledEvent)

pub type SkuId =
  Id(Sku)

pub type StickerId =
  Id(Sticker)

pub type SubscriptionListingId =
  Id(SubscriptionListing)

pub type UserId =
  Id(User)

pub type WebhookId =
  Id(Webhook)

/// Names a tag as a value, so `retag` can be told which one to produce. Empty
/// and opaque: the constants below are the only ones there are.
pub opaque type Tag(kind) {
  Tag
}

pub const application: Tag(Application) = Tag

pub const attachment: Tag(Attachment) = Tag

pub const channel: Tag(Channel) = Tag

pub const command: Tag(Command) = Tag

pub const emoji: Tag(Emoji) = Tag

pub const guild: Tag(Guild) = Tag

pub const integration: Tag(Integration) = Tag

pub const interaction: Tag(Interaction) = Tag

pub const message: Tag(Message) = Tag

pub const overwrite: Tag(Overwrite) = Tag

pub const role: Tag(Role) = Tag

pub const scheduled_event: Tag(ScheduledEvent) = Tag

pub const sku: Tag(Sku) = Tag

pub const sticker: Tag(Sticker) = Tag

pub const subscription_listing: Tag(SubscriptionListing) = Tag

pub const user: Tag(User) = Tag

pub const webhook: Tag(Webhook) = Tag

/// An ID minted from a string you trust: a literal, or text you have already
/// checked. Does not validate, and IDs go straight into request paths, so
/// `parse` anything that came from outside.
pub fn from_string(text: String) -> Id(kind) {
  Id(text)
}

/// The same ID under a different tag, for the places Discord hands one thing
/// out under two names. Only relabels an ID you already hold: unlike
/// `from_string` it cannot bring new text in.
///
/// The destination is a tag value rather than inference, so the call site says
/// what it is making and the compiler holds you to it:
///
/// ```gleam
/// id.retag(overwrite.id, to: id.role)
/// ```
pub fn retag(id: Id(a), to _tag: Tag(b)) -> Id(b) {
  Id(id.text)
}

/// An ID from untrusted input: digits only, no leading zero and no wider than
/// a snowflake, which is every ID Discord issues. Rejects `@me` and anything
/// with a path separator.
pub fn parse(text: String) -> Result(Id(kind), Nil) {
  case string.to_graphemes(text) {
    [] -> Error(Nil)
    ["0"] -> Ok(Id(text))
    ["0", ..] -> Error(Nil)
    chars ->
      // The numeric bound, not a digit count: 20 digits also spells values
      // above 2^64 - 1, and `created_at_ms` has to read everything parse takes.
      case list.all(chars, is_digit), int.parse(text) {
        True, Ok(snowflake) if snowflake <= max_snowflake -> Ok(Id(text))
        _, _ -> Error(Nil)
      }
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Numerically, which for snowflakes is oldest first. Length first because
/// string order is wrong: IDs run 15 to 19 digits with no leading zero.
pub fn compare(a: Id(kind), b: Id(kind)) -> Order {
  let la = string.length(a.text)
  let lb = string.length(b.text)
  case int.compare(la, lb) {
    order.Eq -> string.compare(a.text, b.text)
    other -> other
  }
}

/// A snowflake's low 22 bits are a worker, a process and a counter.
const timestamp_shift: Int = 22

/// 2^64 - 1, the widest snowflake there is.
const max_snowflake: Int = 18_446_744_073_709_551_615

/// When this thing was created, in milliseconds since the Unix epoch. `Error`
/// when the ID is not a snowflake: not a number at all, or wider than one.
/// `parse` rejects both, so only an ID minted with `from_string` can fail.
pub fn created_at_ms(id: Id(kind)) -> Result(Int, Nil) {
  case id.text, int.parse(id.text) {
    // `int.parse` takes a leading sign, which no snowflake has.
    "+" <> _, _ | "-" <> _, _ -> Error(Nil)
    _, Ok(snowflake) if snowflake <= max_snowflake ->
      Ok(int.bitwise_shift_right(snowflake, timestamp_shift) + discord_epoch_ms)
    _, _ -> Error(Nil)
  }
}

/// `created_at_ms` for a caller that has to answer with a number either way.
/// `discord_epoch_ms` is usually the default to reach for: it reads as the
/// oldest snowflake there is, so an ID that is not one sorts as ancient
/// rather than as this instant.
pub fn created_at_ms_or(id: Id(kind), default default: Int) -> Int {
  case created_at_ms(id) {
    Ok(at) -> at
    Error(Nil) -> default
  }
}

/// Discord's epoch, 2015-01-01T00:00:00Z, in milliseconds.
pub const discord_epoch_ms: Int = 1_420_070_400_000

pub fn to_string(id: Id(kind)) -> String {
  id.text
}

pub fn to_json(id: Id(kind)) -> Json {
  json.string(id.text)
}

/// Strings only: Discord always sends a snowflake as a JSON string, so a
/// number in that slot is a malformed payload.
pub fn decoder() -> Decoder(Id(kind)) {
  decode.string |> decode.map(Id)
}
