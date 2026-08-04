//// Message components: action rows, buttons and select menus.
////
//// Two positions, two types. A `Component` is a top-level entry on a message:
//// today only an action row. A `RowChild` is what sits inside a row: a button,
//// a select menu. Discord answers 400 to a row nested in a row and to a button
//// at top level, and neither is a value that can be built here.
////
//// Types 1, 2, 3, 5, 6, 7 and 8 are modelled. Everything else is dropped from
//// the list on decode, so another bot's Components V2 message does not sink
//// your MESSAGE_CREATE.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/channel
import glyde/emoji
import glyde/field.{Present}
import glyde/id
import glyde/wire

/// A top-level entry in a message's `components`. A component type this build
/// does not model is dropped from the list on decode.
pub type Component {
  /// Type 1. Holds up to five buttons, or exactly one select menu.
  ActionRow(
    /// Discord's per-component sequence number, not a snowflake.
    id: Option(Int),
    components: List(RowChild),
  )
}

/// What an action row holds. Never a row: Discord answers 400 to a nested one,
/// and never a Components V2 element, which is top level. A child type this
/// build does not model is dropped from the row on decode.
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
}

/// Discord's `type` number, the one field both positions carry. Types 9 to 23
/// are Components V2, unmodelled, and a value this build has no name for
/// decodes as `None`.
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

/// A style this build has no name for decodes as `None`, so an action button
/// carrying one is dropped from its row.
pub type ButtonStyle {
  PrimaryButton
  SecondaryButton
  SuccessButton
  DangerButton
}

pub type SelectKind {
  /// Type 3. Carries 1 to 25 options.
  StringSelect(options: List(SelectOption))
  /// Type 5.
  UserSelect(default_users: List(id.UserId))
  /// Type 6.
  RoleSelect(default_roles: List(id.RoleId))
  /// Type 7. Resolves to users and roles together.
  MentionableSelect(default_values: List(MentionableDefault))
  /// Type 8.
  ChannelSelect(
    /// Empty means every channel type is offered.
    channel_types: List(channel.ChannelType),
    default_channels: List(id.ChannelId),
  )
}

/// A pre-selected entry on a mentionable select. A channel is not one of the
/// two things a mentionable menu picks, so it is not a value here.
pub type MentionableDefault {
  MentionUser(id.UserId)
  MentionRole(id.RoleId)
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
/// This is the wire shape: the `SelectKind` variants each hold only the ids
/// their menu accepts, and rebuild these on the way out.
type DefaultValue {
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
      case child {
        // Discord takes five buttons to a row.
        Button(..) -> {
          let pending_reversed = [child, ..pending_reversed]
          case list.length(pending_reversed) {
            5 -> pack(rest, [], [row(pending_reversed), ..done_reversed])
            _ -> pack(rest, pending_reversed, done_reversed)
          }
        }

        // A select menu takes a whole row.
        SelectMenu(..) ->
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

pub fn component_type_from_int(value: Int) -> Option(ComponentType) {
  case value {
    1 -> Some(ActionRowType)
    2 -> Some(ButtonType)
    3 -> Some(StringSelectType)
    4 -> Some(TextInputType)
    5 -> Some(UserSelectType)
    6 -> Some(RoleSelectType)
    7 -> Some(MentionableSelectType)
    8 -> Some(ChannelSelectType)
    _ -> None
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
  }
}

pub fn component_type(component: Component) -> ComponentType {
  case component {
    ActionRow(..) -> ActionRowType
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
  }
}

pub fn button_style_from_int(value: Int) -> Option(ButtonStyle) {
  case value {
    1 -> Some(PrimaryButton)
    2 -> Some(SecondaryButton)
    3 -> Some(SuccessButton)
    4 -> Some(DangerButton)
    _ -> None
  }
}

pub fn button_style_to_int(value: ButtonStyle) -> Int {
  case value {
    PrimaryButton -> 1
    SecondaryButton -> 2
    SuccessButton -> 3
    DangerButton -> 4
  }
}

pub fn button_style_decoder() -> Decoder(Option(ButtonStyle)) {
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

/// A top-level component that is not an action row is dropped: `None` here,
/// filtered by `wire.known_list_field` at the call site. A button at top
/// level is a 400 on the way back out, so it is not decoded into one either.
pub fn decoder() -> Decoder(Option(Component)) {
  use type_ <- decode.field("type", wire.integer())
  case component_type_from_int(type_) {
    Some(ActionRowType) -> {
      use id <- wire.opt_field("id", wire.integer())
      use components <- wire.known_list_field("components", row_child_decoder())
      decode.success(Some(ActionRow(id:, components:)))
    }

    _ -> decode.success(None)
  }
}

/// A child that is not a button or a select menu is dropped from its row.
/// That covers a text input, a nested row, and a button whose fields cannot
/// build a `ButtonKind` this side would send back.
pub fn row_child_decoder() -> Decoder(Option(RowChild)) {
  use type_ <- decode.field("type", wire.integer())
  case component_type_from_int(type_) {
    Some(ButtonType) -> {
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
      // button that says nothing, an action button whose style this build
      // cannot name: none of those has a kind to build, so the child is
      // dropped rather than rebuilt into a button that cannot be sent.
      let kind = case style, url, sku_id, custom_id, says {
        5, Some(url), _, _, Ok(says) -> Some(LinkButton(url:, label: says))
        6, _, Some(sku_id), _, _ -> Some(PremiumButton(sku_id:))
        5, _, _, _, _ | 6, _, _, _, _ -> None
        style, _, _, Some(custom_id), Ok(says) ->
          case button_style_from_int(style) {
            Some(style) -> Some(ActionButton(custom_id:, style:, label: says))
            None -> None
          }
        _, _, _, _, _ -> None
      }
      decode.success(case kind {
        Some(kind) -> Some(Button(id:, kind:, disabled:))
        None -> None
      })
    }

    Some(StringSelectType) as declared
    | Some(UserSelectType) as declared
    | Some(RoleSelectType) as declared
    | Some(MentionableSelectType) as declared
    | Some(ChannelSelectType) as declared ->
      select_menu_decoder(declared) |> decode.map(Some)

    // A text input, a row inside a row, or a type this build has no name for.
    Some(ActionRowType) | Some(TextInputType) | None -> decode.success(None)
  }
}

fn select_menu_decoder(declared: Option(ComponentType)) -> Decoder(RowChild) {
  use id <- wire.opt_field("id", wire.integer())
  use custom_id <- wire.string_field("custom_id", "")
  use options <- wire.list_field("options", select_option_decoder())
  use channel_types <- wire.known_list_field(
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
  // Discord already agrees the entry kind with the menu kind, so an entry
  // that does not fit is dropped rather than kept where it cannot be sent
  // back.
  let kind = case declared {
    Some(StringSelectType) -> StringSelect(options:)
    Some(UserSelectType) ->
      UserSelect(
        default_users: list.filter_map(default_values, fn(d) {
          case d {
            DefaultUser(id) -> Ok(id)
            _ -> Error(Nil)
          }
        }),
      )
    Some(RoleSelectType) ->
      RoleSelect(
        default_roles: list.filter_map(default_values, fn(d) {
          case d {
            DefaultRole(id) -> Ok(id)
            _ -> Error(Nil)
          }
        }),
      )
    Some(MentionableSelectType) ->
      MentionableSelect(
        default_values: list.filter_map(default_values, fn(d) {
          case d {
            DefaultUser(id) -> Ok(MentionUser(id))
            DefaultRole(id) -> Ok(MentionRole(id))
            DefaultChannel(_) -> Error(Nil)
          }
        }),
      )
    // Only ChannelSelectType reaches this arm; the caller passes only the
    // five select types. The rest are named so a new ComponentType is a
    // compile error here, not a silent ChannelSelect.
    Some(ChannelSelectType)
    | Some(ActionRowType)
    | Some(ButtonType)
    | Some(TextInputType)
    | None ->
      ChannelSelect(
        channel_types:,
        default_channels: list.filter_map(default_values, fn(d) {
          case d {
            DefaultChannel(id) -> Ok(id)
            _ -> Error(Nil)
          }
        }),
      )
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
fn default_value_decoder() -> Decoder(DefaultValue) {
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
        #("type", Present(json.int(type_))),
        #("id", wire.opt(id) |> wire.put(json.int)),
        #("components", Present(json.array(components, row_child_to_json))),
      ])
  }
}

pub fn row_child_to_json(child: RowChild) -> Json {
  let type_ = component_type_to_int(row_child_type(child))
  case child {
    Button(id:, kind:, disabled:) -> {
      let #(label, custom_id, url, sku_id) = button_kind_parts(kind)
      let #(text, icon) = button_label_parts(label)
      wire.object([
        #("type", Present(json.int(type_))),
        #("id", wire.opt(id) |> wire.put(json.int)),
        #("style", Present(json.int(button_kind_style(kind)))),
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
        #("type", Present(json.int(type_))),
        #("custom_id", Present(json.string(custom_id))),
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
    UserSelect(default_users:) -> #(
      None,
      None,
      list.map(default_users, DefaultUser),
    )
    RoleSelect(default_roles:) -> #(
      None,
      None,
      list.map(default_roles, DefaultRole),
    )
    MentionableSelect(default_values:) -> #(
      None,
      None,
      list.map(default_values, fn(d) {
        case d {
          MentionUser(id) -> DefaultUser(id)
          MentionRole(id) -> DefaultRole(id)
        }
      }),
    )
    ChannelSelect(channel_types:, default_channels:) -> #(
      None,
      Some(channel_types),
      list.map(default_channels, DefaultChannel),
    )
  }
}

pub fn select_option_to_json(item: SelectOption) -> Json {
  wire.object([
    #("label", Present(json.string(item.label))),
    #("value", Present(json.string(item.value))),
    #("description", wire.opt(item.description) |> wire.put(json.string)),
    #("emoji", wire.opt(item.emoji) |> wire.put(emoji.to_json)),
    #("default", wire.flag(item.default)),
  ])
}

fn default_value_to_json(value: DefaultValue) -> Json {
  let #(raw, kind) = case value {
    DefaultUser(id:) -> #(id.to_json(id), "user")
    DefaultRole(id:) -> #(id.to_json(id), "role")
    DefaultChannel(id:) -> #(id.to_json(id), "channel")
  }
  json.object([#("id", raw), #("type", json.string(kind))])
}
