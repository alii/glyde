//// Message components: action rows, buttons and select menus.
////
//// Two positions, two types. A `Component` is a top-level entry on a message:
//// an action row, or a Components V2 element. A `RowChild` is what sits inside
//// a row: a button, a select menu. Discord answers 400 to a row nested in a
//// row and to a button at top level, and neither is a value that can be built
//// here.
////
//// Types 1, 2, 3, 5, 6, 7 and 8 are modelled. Everything else keeps its
//// payload intact, so another bot's Components V2 message does not sink your
//// MESSAGE_CREATE.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some} as _
import gleam/order.{type Order}
import gleam/string
import glyde/id
import glyde/model/channel
import glyde/model/emoji
import glyde/wire

/// A top-level entry in a message's `components`.
pub type Component {
  /// Type 1. Holds up to five buttons, or exactly one select menu.
  ActionRow(
    /// Discord's per-component sequence number, not a snowflake.
    id: Option(Int),
    components: List(RowChild),
  )

  /// Types 9 to 23, the Components V2 elements, and anything else that arrived
  /// where a row belongs. The raw payload is kept, so it can be sent back
  /// unchanged.
  UnknownComponent(type_: Int, raw: RawPayload)
}

/// What an action row holds. Never a row: Discord answers 400 to a nested one,
/// and never a Components V2 element, which is top level.
pub type RowChild {
  /// Type 2. What it says is in `kind`: a premium button takes its label from
  /// the SKU, and the other two need one of their own.
  Button(id: Option(Int), kind: ButtonKind, disabled: Bool)

  /// Types 3, 5, 6, 7 and 8. `kind` is the discriminator.
  SelectMenu(
    id: Option(Int),
    /// 1 to 100 characters, chosen by you.
    custom_id: String,
    kind: SelectKind,
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Bool,
  )

  /// Type 4, the text input a modal puts in a row, and a type 2 with no kind
  /// to degrade to: a button Discord would reject. The raw payload is kept, so
  /// it can be sent back unchanged.
  UnknownChild(type_: Int, raw: RawPayload)
}

/// A payload this build does not model, read once into keys and values. The
/// read happens at decode time, where a malformed payload is expected, so
/// nothing downstream has to handle a failure by dropping the lot.
pub opaque type RawPayload {
  RawPayload(entries: dict.Dict(String, Json))
}

/// `Error(Nil)` when the value is not a JSON object. Decoders fall back to
/// `empty_raw_payload`; nothing else needs to.
pub fn raw_payload(value: Dynamic) -> Result(RawPayload, Nil) {
  case decode.run(value, decode.dict(decode.string, raw_decoder())) {
    Ok(entries) -> Ok(RawPayload(entries:))
    Error(_) -> Error(Nil)
  }
}

pub fn empty_raw_payload() -> RawPayload {
  RawPayload(entries: dict.new())
}

/// The keys as they will be written, sorted: a `Dict` has no order of its own
/// and these become request bytes.
pub fn raw_payload_entries(payload: RawPayload) -> List(#(String, Json)) {
  payload.entries |> dict.to_list |> list.sort(by_key)
}

/// Discord's `type` number, the one field both positions carry. Types 9 to 23
/// are Components V2, unmodelled, and arrive as `UnknownComponentType`.
pub type ComponentType {
  ActionRowType
  ButtonType
  StringSelectType
  /// A modal's text input, one per action row.
  TextInputType
  UserSelectType
  RoleSelectType
  MentionableSelectType
  ChannelSelectType
  UnknownComponentType(Int)
}

/// A link button with a `custom_id` is a 400, so each kind carries only the
/// fields its style allows. Styles 5 and 6 are the link and premium buttons.
pub type ButtonKind {
  ActionButton(custom_id: String, style: ButtonStyle, label: ButtonLabel)
  LinkButton(url: String, label: ButtonLabel)
  /// Discord supplies the label from the SKU, so this one takes none.
  PremiumButton(sku_id: id.SkuId)
}

/// Discord needs a button to say something, so "no label and no emoji" is not
/// a state to have. Text is max 80 characters.
pub type ButtonLabel {
  Text(String)
  Icon(emoji.Emoji)
  TextAndIcon(String, emoji.Emoji)
}

pub type ButtonStyle {
  PrimaryButton
  SecondaryButton
  SuccessButton
  DangerButton
  UnknownButtonStyle(Int)
}

pub type SelectKind {
  /// Type 3. Carries 1 to 25 options.
  StringSelect(options: List(SelectOption))
  /// Type 5.
  UserSelect(default_values: List(DefaultValue))
  /// Type 6.
  RoleSelect(default_values: List(DefaultValue))
  /// Type 7. Resolves to users and roles together.
  MentionableSelect(default_values: List(DefaultValue))
  /// Type 8.
  ChannelSelect(
    /// Empty means every channel type is offered.
    channel_types: List(channel.ChannelType),
    default_values: List(DefaultValue),
  )
}

pub type SelectOption {
  SelectOption(
    /// Max 100 characters, shown to the user.
    label: String,
    /// Max 100 characters, sent back to you on click.
    value: String,
    description: Option(String),
    emoji: Option(emoji.Emoji),
    default: Bool,
  )
}

/// A pre-selected entry on an entity select, tagged so id and kind agree.
pub type DefaultValue {
  DefaultUser(id: id.UserId)
  DefaultRole(id: id.RoleId)
  DefaultChannel(id: id.ChannelId)
}

/// `PrimaryButton` is our default, not Discord's: the API requires a style and
/// has none of its own. Change it with a record update.
pub fn button(custom_id custom_id: String, label label: String) -> RowChild {
  Button(
    id: None,
    kind: ActionButton(custom_id:, style: PrimaryButton, label: Text(label)),
    disabled: False,
  )
}

/// Opens a url, and sends no interaction.
pub fn link_button(url url: String, label label: String) -> RowChild {
  Button(id: None, kind: LinkButton(url:, label: Text(label)), disabled: False)
}

/// A premium upsell. Discord supplies the label from the SKU.
pub fn premium_button(sku_id: id.SkuId) -> RowChild {
  Button(id: None, kind: PremiumButton(sku_id:), disabled: False)
}

pub fn select(custom_id custom_id: String, kind kind: SelectKind) -> RowChild {
  SelectMenu(
    id: None,
    custom_id:,
    kind:,
    placeholder: None,
    min_values: None,
    max_values: None,
    disabled: False,
  )
}

pub fn option(label label: String, value value: String) -> SelectOption {
  SelectOption(label:, value:, description: None, emoji: None, default: False)
}

/// Pack loose children into action rows: five buttons to a row, a whole row
/// per select menu, order preserved. A row and a Components V2 element are top
/// level, so they are not inputs here: append them to what this returns.
pub fn rows(children: List(RowChild)) -> List(Component) {
  let #(packed, pending) = pack(children, [], [])
  list.reverse(flush(pending, packed))
}

fn pack(
  remaining: List(RowChild),
  pending_reversed: List(RowChild),
  done_reversed: List(Component),
) -> #(List(Component), List(RowChild)) {
  case remaining {
    [] -> #(done_reversed, pending_reversed)

    [child, ..rest] ->
      case row_child_type(child) {
        // A type 2 that failed to decode is still a button, and Discord takes
        // five of them to a row.
        ButtonType -> {
          let pending_reversed = [child, ..pending_reversed]
          case list.length(pending_reversed) {
            5 -> pack(rest, [], [row(pending_reversed), ..done_reversed])
            _ -> pack(rest, pending_reversed, done_reversed)
          }
        }

        // A select menu takes a whole row, and so does a text input: type 4 is
        // one per row in a modal.
        _ ->
          pack(rest, [], [
            row([child]),
            ..flush(pending_reversed, done_reversed)
          ])
      }
  }
}

fn flush(
  pending_reversed: List(RowChild),
  done_reversed: List(Component),
) -> List(Component) {
  case pending_reversed {
    [] -> done_reversed
    _ -> [row(pending_reversed), ..done_reversed]
  }
}

fn row(reversed: List(RowChild)) -> Component {
  ActionRow(id: None, components: list.reverse(reversed))
}

pub fn component_type_from_int(value: Int) -> ComponentType {
  case value {
    1 -> ActionRowType
    2 -> ButtonType
    3 -> StringSelectType
    4 -> TextInputType
    5 -> UserSelectType
    6 -> RoleSelectType
    7 -> MentionableSelectType
    8 -> ChannelSelectType
    other -> UnknownComponentType(other)
  }
}

pub fn component_type_to_int(value: ComponentType) -> Int {
  case value {
    ActionRowType -> 1
    ButtonType -> 2
    StringSelectType -> 3
    TextInputType -> 4
    UserSelectType -> 5
    RoleSelectType -> 6
    MentionableSelectType -> 7
    ChannelSelectType -> 8
    UnknownComponentType(other) -> other
  }
}

pub fn component_type(component: Component) -> ComponentType {
  case component {
    ActionRow(..) -> ActionRowType
    UnknownComponent(type_:, ..) -> component_type_from_int(type_)
  }
}

pub fn row_child_type(child: RowChild) -> ComponentType {
  case child {
    Button(..) -> ButtonType
    SelectMenu(kind: StringSelect(..), ..) -> StringSelectType
    SelectMenu(kind: UserSelect(..), ..) -> UserSelectType
    SelectMenu(kind: RoleSelect(..), ..) -> RoleSelectType
    SelectMenu(kind: MentionableSelect(..), ..) -> MentionableSelectType
    SelectMenu(kind: ChannelSelect(..), ..) -> ChannelSelectType
    UnknownChild(type_:, ..) -> component_type_from_int(type_)
  }
}

pub fn button_style_from_int(value: Int) -> ButtonStyle {
  case value {
    1 -> PrimaryButton
    2 -> SecondaryButton
    3 -> SuccessButton
    4 -> DangerButton
    other -> UnknownButtonStyle(other)
  }
}

pub fn button_style_to_int(value: ButtonStyle) -> Int {
  case value {
    PrimaryButton -> 1
    SecondaryButton -> 2
    SuccessButton -> 3
    DangerButton -> 4
    UnknownButtonStyle(other) -> other
  }
}

pub fn button_style_decoder() -> Decoder(ButtonStyle) {
  wire.integer() |> decode.map(button_style_from_int)
}

pub fn button_style_to_json(value: ButtonStyle) -> Json {
  json.int(button_style_to_int(value))
}

/// A button with neither is a 400 from Discord and not a payload it sends, so
/// there is no `ButtonLabel` for it and the caller degrades instead. Inventing
/// an empty label would add a `"label":""` the payload never carried.
fn button_label(
  label: Option(String),
  icon: Option(emoji.Emoji),
) -> Result(ButtonLabel, Nil) {
  case label, icon {
    Some(text), Some(icon) -> Ok(TextAndIcon(text, icon))
    Some(text), None -> Ok(Text(text))
    None, Some(icon) -> Ok(Icon(icon))
    None, None -> Error(Nil)
  }
}

/// Link buttons are style 5 and premium buttons style 6, whatever the
/// `ButtonStyle` set says.
fn button_kind_style(kind: ButtonKind) -> Int {
  case kind {
    ActionButton(style:, ..) -> button_style_to_int(style)
    LinkButton(..) -> 5
    PremiumButton(..) -> 6
  }
}

pub fn decoder() -> Decoder(Component) {
  use type_ <- decode.field("type", wire.integer())
  case component_type_from_int(type_) {
    ActionRowType -> {
      use id <- wire.opt_field("id", wire.integer())
      use components <- wire.list_field("components", row_child_decoder())
      decode.success(ActionRow(id:, components:))
    }

    // A button at top level is a 400 on the way back out, so it is not decoded
    // into one: the payload is kept as it arrived.
    _ -> {
      use raw <- wire.raw()
      decode.success(UnknownComponent(type_:, raw: raw_or_empty(raw)))
    }
  }
}

pub fn row_child_decoder() -> Decoder(RowChild) {
  use type_ <- decode.field("type", wire.integer())
  let declared = component_type_from_int(type_)
  case declared {
    ButtonType -> {
      use raw <- wire.raw()
      use id <- wire.opt_field("id", wire.integer())
      use style <- wire.int_field("style", 2)
      use label <- wire.opt_field("label", decode.string)
      use emoji <- wire.opt_field("emoji", emoji.decoder())
      use disabled <- wire.flag_field("disabled", False)
      use custom_id <- wire.opt_field("custom_id", decode.string)
      use url <- wire.opt_field("url", decode.string)
      use sku_id <- wire.opt_field("sku_id", id.decoder())
      let says = button_label(label, emoji)
      // Every kind here is one Discord would take back. A link with no url, a
      // premium button with no sku, an action button with no custom_id, a
      // button that says nothing: none of those has a kind to degrade to, so
      // the payload is kept as it arrived rather than rebuilt into a button
      // that cannot be sent.
      let kind = case style, url, sku_id, custom_id, says {
        5, Some(url), _, _, Ok(says) -> Ok(LinkButton(url:, label: says))
        6, _, Some(sku_id), _, _ -> Ok(PremiumButton(sku_id:))
        5, _, _, _, _ | 6, _, _, _, _ -> Error(Nil)
        style, _, _, Some(custom_id), Ok(says) ->
          Ok(ActionButton(
            custom_id:,
            style: button_style_from_int(style),
            label: says,
          ))
        _, _, _, _, _ -> Error(Nil)
      }
      case kind {
        Ok(kind) -> decode.success(Button(id:, kind:, disabled:))
        Error(Nil) -> decode.success(UnknownChild(2, raw_or_empty(raw)))
      }
    }

    StringSelectType
    | UserSelectType
    | RoleSelectType
    | MentionableSelectType
    | ChannelSelectType -> {
      use id <- wire.opt_field("id", wire.integer())
      use custom_id <- wire.string_field("custom_id", "")
      use options <- wire.list_field("options", select_option_decoder())
      use channel_types <- wire.list_field(
        "channel_types",
        channel.channel_type_decoder(),
      )
      use default_values <- wire.list_field(
        "default_values",
        default_value_decoder(),
      )
      use placeholder <- wire.opt_field("placeholder", decode.string)
      use min_values <- wire.opt_field("min_values", wire.integer())
      use max_values <- wire.opt_field("max_values", wire.integer())
      use disabled <- wire.flag_field("disabled", False)
      let kind = case declared {
        StringSelectType -> StringSelect(options:)
        UserSelectType -> UserSelect(default_values:)
        RoleSelectType -> RoleSelect(default_values:)
        MentionableSelectType -> MentionableSelect(default_values:)
        _ -> ChannelSelect(channel_types:, default_values:)
      }
      decode.success(SelectMenu(
        id:,
        custom_id:,
        kind:,
        placeholder:,
        min_values:,
        max_values:,
        disabled:,
      ))
    }

    // A text input, or a row Discord would reject inside a row. Keeping the
    // payload beats failing someone else's message.
    _ -> {
      use raw <- wire.raw()
      decode.success(UnknownChild(type_:, raw: raw_or_empty(raw)))
    }
  }
}

/// The one place a payload may fail to read as an object, and the `type` field
/// above has already ruled that out. Everywhere else holds a `RawPayload`, so
/// no encoder has to guess what to do with a failure.
fn raw_or_empty(value: Dynamic) -> RawPayload {
  case raw_payload(value) {
    Ok(payload) -> payload
    Error(Nil) -> empty_raw_payload()
  }
}

pub fn select_option_decoder() -> Decoder(SelectOption) {
  use label <- wire.string_field("label", "")
  use value <- wire.string_field("value", "")
  use description <- wire.opt_field("description", decode.string)
  use emoji <- wire.opt_field("emoji", emoji.decoder())
  use default <- wire.flag_field("default", False)
  decode.success(SelectOption(label:, value:, description:, emoji:, default:))
}

/// An unrecognised `type` fails the whole select menu on purpose: a default
/// dropped silently would pre-select the wrong thing.
pub fn default_value_decoder() -> Decoder(DefaultValue) {
  use type_ <- decode.field("type", decode.string)
  // `id.Id` is tagged, so one binding cannot be a UserId here and a RoleId
  // there.
  case type_ {
    "user" -> {
      use id <- decode.field("id", id.decoder())
      decode.success(DefaultUser(id:))
    }
    "role" -> {
      use id <- decode.field("id", id.decoder())
      decode.success(DefaultRole(id:))
    }
    "channel" -> {
      use id <- decode.field("id", id.decoder())
      decode.success(DefaultChannel(id:))
    }
    _ -> decode.failure(DefaultUser(id.from_string("")), "DefaultValue")
  }
}

pub fn to_json(component: Component) -> Json {
  // One source for the wire type, so what is emitted and what
  // `component_type` reports cannot drift apart.
  let type_ = component_type_to_int(component_type(component))
  case component {
    ActionRow(id:, components:) ->
      wire.object([
        #("type", wire.present(json.int(type_))),
        #("id", wire.opt(id) |> wire.put(json.int)),
        #("components", wire.present(json.array(components, row_child_to_json))),
      ])

    UnknownComponent(raw:, ..) -> raw_to_json(type_, raw)
  }
}

pub fn row_child_to_json(child: RowChild) -> Json {
  let type_ = component_type_to_int(row_child_type(child))
  case child {
    Button(id:, kind:, disabled:) -> {
      let #(label, custom_id, url, sku_id) = button_kind_parts(kind)
      let #(text, icon) = button_label_parts(label)
      wire.object([
        #("type", wire.present(json.int(type_))),
        #("id", wire.opt(id) |> wire.put(json.int)),
        #("style", wire.present(json.int(button_kind_style(kind)))),
        #("label", wire.opt(text) |> wire.put(json.string)),
        #("emoji", wire.opt(icon) |> wire.put(emoji.to_json)),
        #("custom_id", wire.opt(custom_id) |> wire.put(json.string)),
        #("url", wire.opt(url) |> wire.put(json.string)),
        #("sku_id", wire.opt(sku_id) |> wire.put(id.to_json)),
        #("disabled", wire.flag(disabled)),
      ])
    }

    SelectMenu(
      id:,
      custom_id:,
      kind:,
      placeholder:,
      min_values:,
      max_values:,
      disabled:,
    ) -> {
      let #(options, channel_types, default_values) = select_kind_parts(kind)
      wire.object([
        #("type", wire.present(json.int(type_))),
        #("custom_id", wire.present(json.string(custom_id))),
        #("id", wire.opt(id) |> wire.put(json.int)),
        #("options", wire.opt(options) |> wire.put_list(select_option_to_json)),
        #(
          "channel_types",
          wire.opt(channel_types)
            |> wire.put_list(channel.channel_type_to_json),
        ),
        #(
          "default_values",
          wire.opt_list(default_values) |> wire.put_list(default_value_to_json),
        ),
        #("placeholder", wire.opt(placeholder) |> wire.put(json.string)),
        #("min_values", wire.opt(min_values) |> wire.put(json.int)),
        #("max_values", wire.opt(max_values) |> wire.put(json.int)),
        #("disabled", wire.flag(disabled)),
      ])
    }

    UnknownChild(raw:, ..) -> raw_to_json(type_, raw)
  }
}

/// The keys a button carries beyond its style: a label, and the one field its
/// kind is named for. `label` and `emoji` go out before that field, which is
/// the order Discord's own examples use.
fn button_kind_parts(
  kind: ButtonKind,
) -> #(Option(ButtonLabel), Option(String), Option(String), Option(id.SkuId)) {
  case kind {
    ActionButton(custom_id:, label:, ..) -> #(
      Some(label),
      Some(custom_id),
      None,
      None,
    )
    LinkButton(url:, label:) -> #(Some(label), None, Some(url), None)
    PremiumButton(sku_id:) -> #(None, None, None, Some(sku_id))
  }
}

fn button_label_parts(
  label: Option(ButtonLabel),
) -> #(Option(String), Option(emoji.Emoji)) {
  case label {
    Some(Text(text)) -> #(Some(text), None)
    Some(Icon(icon)) -> #(None, Some(icon))
    Some(TextAndIcon(text, icon)) -> #(Some(text), Some(icon))
    None -> #(None, None)
  }
}

/// `options` and `channel_types` go out even when empty, because the kind
/// says which one the menu is. `default_values` does not: an empty array
/// there means the same as no key.
fn select_kind_parts(
  kind: SelectKind,
) -> #(
  Option(List(SelectOption)),
  Option(List(channel.ChannelType)),
  List(DefaultValue),
) {
  case kind {
    StringSelect(options:) -> #(Some(options), None, [])
    UserSelect(default_values:)
    | RoleSelect(default_values:)
    | MentionableSelect(default_values:) -> #(None, None, default_values)
    ChannelSelect(channel_types:, default_values:) -> #(
      None,
      Some(channel_types),
      default_values,
    )
  }
}

pub fn select_option_to_json(item: SelectOption) -> Json {
  wire.object([
    #("label", wire.present(json.string(item.label))),
    #("value", wire.present(json.string(item.value))),
    #("description", wire.opt(item.description) |> wire.put(json.string)),
    #("emoji", wire.opt(item.emoji) |> wire.put(emoji.to_json)),
    #("default", wire.flag(item.default)),
  ])
}

pub fn default_value_to_json(value: DefaultValue) -> Json {
  let #(raw, kind) = case value {
    DefaultUser(id:) -> #(id.to_json(id), "user")
    DefaultRole(id:) -> #(id.to_json(id), "role")
    DefaultChannel(id:) -> #(id.to_json(id), "channel")
  }
  json.object([#("id", raw), #("type", json.string(kind))])
}

/// Back to JSON, for the unmodelled types. Values survive and key order does
/// not: `Dict` order is unspecified, so keys come out sorted. The `type` is
/// written here rather than kept, so it is the one `component_type` reports
/// even if the payload was built by hand.
fn raw_to_json(type_: Int, raw: RawPayload) -> Json {
  raw.entries
  |> dict.insert("type", json.int(type_))
  |> dict.to_list
  |> list.sort(by_key)
  |> json.object
}

/// Order matters: `int` before `float`, or a JSON integer comes back out with
/// a decimal point.
fn raw_decoder() -> Decoder(Json) {
  use <- decode.recursive
  decode.one_of(decode.bool |> decode.map(json.bool), [
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.string |> decode.map(json.string),
    decode.list(raw_decoder()) |> decode.map(json.preprocessed_array),
    decode.dict(decode.string, raw_decoder())
      |> decode.map(fn(entries) {
        json.object(list.sort(dict.to_list(entries), by_key))
      }),
    decode.success(json.null()),
  ])
}

fn by_key(a: #(String, Json), b: #(String, Json)) -> Order {
  string.compare(a.0, b.0)
}
