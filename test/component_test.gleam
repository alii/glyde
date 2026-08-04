import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/channel
import glyde/component.{
  ActionButton, ActionRow, Button, ChannelSelect, DangerButton, Icon, LinkButton,
  MentionUser, MentionableSelect, PremiumButton, PrimaryButton, RoleSelect,
  SecondaryButton, SelectMenu, StringSelect, SuccessButton, Text, TextAndIcon,
  UserSelect,
}
import glyde/emoji
import glyde/id

fn modelled(
  inner: decode.Decoder(option.Option(a)),
  zero: a,
) -> decode.Decoder(a) {
  decode.then(inner, fn(found) {
    case found {
      Some(value) -> decode.success(value)
      None -> decode.failure(zero, "modelled")
    }
  })
}

fn parse(text: String) -> Result(component.Component, json.DecodeError) {
  json.parse(
    text,
    modelled(component.decoder(), ActionRow(id: None, components: [])),
  )
}

fn encode(value: component.Component) -> String {
  json.to_string(component.to_json(value))
}

/// A button and a select menu are what a row holds, never a top-level entry,
/// so they parse through their own decoder.
fn parse_child(text: String) -> Result(component.RowChild, json.DecodeError) {
  json.parse(
    text,
    modelled(component.row_child_decoder(), component.button("", "")),
  )
}

fn encode_child(value: component.RowChild) -> String {
  json.to_string(component.row_child_to_json(value))
}

pub fn action_button_decodes_test() {
  let assert Ok(value) =
    parse_child(
      "{\"type\":2,\"style\":4,\"custom_id\":\"delete\",\"label\":\"Delete\",\"id\":3}",
    )
  assert value
    == Button(
      id: Some(3),
      kind: ActionButton(
        custom_id: "delete",
        style: DangerButton,
        label: Text("Delete"),
      ),
      disabled: False,
    )
}

pub fn link_button_decodes_test() {
  let assert Ok(value) =
    parse_child(
      "{\"type\":2,\"style\":5,\"url\":\"https://example.com\",\"label\":\"Go\"}",
    )
  assert value
    == Button(
      id: None,
      kind: LinkButton(url: "https://example.com", label: Text("Go")),
      disabled: False,
    )
}

/// Discord fills the label in from the SKU, so a premium button has nowhere
/// to put one.
pub fn premium_button_decodes_test() {
  let assert Ok(value) =
    parse_child("{\"type\":2,\"style\":6,\"sku_id\":\"1234567890\"}")
  assert value
    == Button(
      id: None,
      kind: PremiumButton(sku_id: id.from_string("1234567890")),
      disabled: False,
    )
}

/// Style 5 with no url is a contradiction, and the message is usually someone
/// else's, so it is dropped rather than failed. It cannot degrade to an
/// action button: a link style with a `custom_id`, or an action button
/// without one, is a 400 on the way back out.
pub fn malformed_button_is_dropped_from_its_row_test() {
  let dropped = fn(text) {
    json.parse(text, component.row_child_decoder()) == Ok(None)
  }

  assert dropped("{\"type\":2,\"style\":5,\"custom_id\":\"x\"}")
  assert dropped("{\"type\":2,\"style\":6}")
  assert dropped("{\"type\":2,\"style\":1,\"label\":\"A\"}")
  // Neither a label nor an emoji is the same class of malformed.
  assert dropped("{\"type\":2,\"style\":1,\"custom_id\":\"x\"}")
  // An action button whose style this build cannot name.
  assert dropped("{\"type\":2,\"style\":9,\"custom_id\":\"x\",\"label\":\"A\"}")
}

/// Discord always sends `style`; a hand-built payload may not.
pub fn absent_button_style_defaults_to_secondary_test() {
  let assert Ok(Button(kind:, ..)) =
    parse_child("{\"type\":2,\"custom_id\":\"x\",\"label\":\"A\"}")
  assert kind
    == ActionButton(custom_id: "x", style: SecondaryButton, label: Text("A"))
}

/// A button says something with text, an emoji, or both, and never neither.
pub fn button_emoji_decodes_test() {
  let assert Ok(Button(kind: ActionButton(label:, ..), ..)) =
    parse_child(
      "{\"type\":2,\"style\":1,\"custom_id\":\"x\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}",
    )
  assert label == Icon(emoji.unicode("🔥"))

  let assert Ok(Button(kind: ActionButton(label: both, ..), ..)) =
    parse_child(
      "{\"type\":2,\"style\":1,\"custom_id\":\"x\",\"label\":\"Burn\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}",
    )
  assert both == TextAndIcon("Burn", emoji.unicode("🔥"))
}

pub fn button_style_round_trips_test() {
  let styles = [
    #(1, PrimaryButton),
    #(2, SecondaryButton),
    #(3, SuccessButton),
    #(4, DangerButton),
  ]
  list.each(styles, fn(row) {
    let #(wire, style) = row
    assert component.button_style_from_int(wire) == Some(style)
    assert component.button_style_to_int(style) == wire
  })
  assert component.button_style_from_int(0) == None
  assert component.button_style_from_int(99) == None
}

pub fn action_row_nests_test() {
  let assert Ok(value) =
    parse(
      "{\"type\":1,\"components\":[{\"type\":2,\"style\":1,\"custom_id\":\"a\",\"label\":\"A\"},"
      <> "{\"type\":2,\"style\":2,\"custom_id\":\"b\",\"label\":\"B\"}]}",
    )
  let assert ActionRow(
    id: None,
    components: [Button(kind: first, ..), Button(kind: second, ..)],
  ) = value
  assert first
    == ActionButton(custom_id: "a", style: PrimaryButton, label: Text("A"))
  assert second
    == ActionButton(custom_id: "b", style: SecondaryButton, label: Text("B"))
}

/// A row inside a row is a 400, and no longer a value that can be built: the
/// inner one is dropped from the outer row's children.
pub fn a_nested_row_is_dropped_test() {
  let assert Ok(ActionRow(components:, ..)) =
    parse(
      "{\"type\":1,\"components\":[{\"type\":1,\"id\":2,\"components\":[]}]}",
    )
  assert components == []
}

/// A modal's text input is type 4, a child this build does not model. The row
/// drops it and keeps the button beside it.
pub fn a_row_filters_unmodelled_children_test() {
  let text =
    "{\"type\":1,\"components\":[{\"custom_id\":\"name\",\"label\":\"Name\","
    <> "\"style\":1,\"type\":4},"
    <> "{\"type\":2,\"style\":1,\"custom_id\":\"go\",\"label\":\"Go\"}]}"
  let assert Ok(ActionRow(components: [kept], ..)) = parse(text)
  let assert Button(kind: ActionButton(custom_id: "go", ..), ..) = kept
}

pub fn string_select_decodes_test() {
  let assert Ok(value) =
    parse_child(
      "{\"type\":3,\"custom_id\":\"pick\",\"placeholder\":\"Choose\","
      <> "\"min_values\":1,\"max_values\":2,\"options\":["
      <> "{\"label\":\"A\",\"value\":\"a\",\"default\":true},"
      <> "{\"label\":\"B\",\"value\":\"b\",\"description\":\"bee\"}]}",
    )
  assert value
    == SelectMenu(
      id: None,
      custom_id: "pick",
      kind: StringSelect(options: [
        component.SelectOption(
          label: "A",
          value: "a",
          description: None,
          emoji: None,
          default: True,
        ),
        component.SelectOption(
          label: "B",
          value: "b",
          description: Some("bee"),
          emoji: None,
          default: False,
        ),
      ]),
      placeholder: Some("Choose"),
      min_values: Some(1),
      max_values: Some(2),
      disabled: False,
    )
}

pub fn entity_selects_decode_test() {
  let cases = [
    #(5, UserSelect(default_users: [id.from_string("1")])),
    #(6, RoleSelect(default_roles: [id.from_string("1")])),
    #(7, MentionableSelect(default_values: [MentionUser(id.from_string("1"))])),
  ]
  list.each(cases, fn(row) {
    let #(wire, expected) = row
    let assert Ok(SelectMenu(kind:, ..)) =
      parse_child(
        "{\"type\":"
        <> int.to_string(wire)
        <> ",\"custom_id\":\"c\",\"default_values\":[{\"id\":\"1\",\"type\":\""
        <> case wire {
          6 -> "role"
          _ -> "user"
        }
        <> "\"}]}",
      )
    assert kind == expected
  })
}

pub fn channel_select_carries_its_channel_types_test() {
  let assert Ok(SelectMenu(kind:, ..)) =
    parse_child(
      "{\"type\":8,\"custom_id\":\"c\",\"channel_types\":[0,2],"
      <> "\"default_values\":[{\"id\":\"9\",\"type\":\"channel\"}]}",
    )
  assert kind
    == ChannelSelect(
      channel_types: [channel.GuildText, channel.GuildVoice],
      default_channels: [id.from_string("9")],
    )
}

/// The select is usually another bot's; a channel type this build has no name
/// for is dropped from the list, and the known one beside it survives.
pub fn unmodelled_channel_type_in_a_select_is_filtered_test() {
  let assert Ok(SelectMenu(kind:, ..)) =
    parse_child("{\"type\":8,\"custom_id\":\"c\",\"channel_types\":[99,0]}")
  assert kind
    == ChannelSelect(channel_types: [channel.GuildText], default_channels: [])
}

/// A dropped default would pre-select the wrong things, so this fails instead.
pub fn unknown_default_value_type_is_an_error_test() {
  let assert Error(_) =
    parse_child(
      "{\"type\":5,\"custom_id\":\"c\",\"default_values\":[{\"id\":\"1\",\"type\":\"guild\"}]}",
    )
}

/// Another bot's Components V2 message arrives in your MESSAGE_CREATE. A type
/// this build has no name for decodes as `None`, so the containing list holds
/// only the rows it can name.
pub fn unmodelled_component_types_are_dropped_test() {
  let types = [4, 9, 10, 12, 17, 23]
  list.each(types, fn(wire) {
    assert json.parse(
        "{\"type\":" <> int.to_string(wire) <> ",\"content\":\"hi\"}",
        component.decoder(),
      )
      == Ok(None)
  })
}

/// One table for the wire numbering, shared with `model/interaction`, which
/// reads the same numbers off a component interaction.
pub fn the_component_type_table_round_trips_test() {
  let table = [
    #(1, component.ActionRowType),
    #(2, component.ButtonType),
    #(3, component.StringSelectType),
    #(4, component.TextInputType),
    #(5, component.UserSelectType),
    #(6, component.RoleSelectType),
    #(7, component.MentionableSelectType),
    #(8, component.ChannelSelectType),
  ]
  list.each(table, fn(row) {
    let #(wire, kind) = row
    assert component.component_type_from_int(wire) == Some(kind)
    assert component.component_type_to_int(kind) == wire
  })
  assert component.component_type_from_int(17) == None
}

pub fn component_type_matches_the_wire_test() {
  assert component.component_type(ActionRow(id: None, components: []))
    == component.ActionRowType

  let children = [
    #(component.button("a", "A"), component.ButtonType),
    #(
      component.select("c", StringSelect(options: [])),
      component.StringSelectType,
    ),
    #(
      component.select("c", UserSelect(default_users: [])),
      component.UserSelectType,
    ),
    #(
      component.select("c", RoleSelect(default_roles: [])),
      component.RoleSelectType,
    ),
    #(
      component.select("c", MentionableSelect(default_values: [])),
      component.MentionableSelectType,
    ),
    #(
      component.select(
        "c",
        ChannelSelect(channel_types: [], default_channels: []),
      ),
      component.ChannelSelectType,
    ),
  ]
  list.each(children, fn(row) {
    let #(value, expected) = row
    assert component.row_child_type(value) == expected
  })
}

/// There is no `list.range`: `int.range` is a fold and excludes `to`.
fn buttons(count: Int) -> List(component.RowChild) {
  int.range(from: count, to: 0, with: [], run: fn(acc, n) {
    let name = int.to_string(n)
    [component.button(name, name), ..acc]
  })
}

fn row_widths(rows: List(component.Component)) -> List(Int) {
  list.map(rows, fn(row) {
    let ActionRow(components:, ..) = row
    list.length(components)
  })
}

/// Buttons go five to a row, which is Discord's limit.
pub fn rows_packs_seven_buttons_into_two_rows_test() {
  assert row_widths(component.rows(buttons(7))) == [5, 2]
}

pub fn rows_packing_table_test() {
  let table = [
    #(0, []),
    #(1, [1]),
    #(5, [5]),
    #(6, [5, 1]),
    #(10, [5, 5]),
    #(11, [5, 5, 1]),
  ]
  list.each(table, fn(row) {
    let #(count, widths) = row
    assert row_widths(component.rows(buttons(count))) == widths
  })
}

/// A select menu takes a whole row.
pub fn rows_gives_a_select_its_own_row_test() {
  let mixed =
    list.flatten([
      buttons(2),
      [component.select("s", StringSelect(options: []))],
      buttons(3),
    ])
  assert row_widths(component.rows(mixed)) == [2, 1, 3]
}

pub fn rows_preserves_order_test() {
  let assert [
    ActionRow(components: first, ..),
    ActionRow(components: second, ..),
  ] = component.rows(buttons(7))
  let ids =
    list.map(list.flatten([first, second]), fn(value) {
      let assert Button(kind: ActionButton(custom_id:, ..), ..) = value
      custom_id
    })
  assert ids == ["1", "2", "3", "4", "5", "6", "7"]
}

/// A row is not a row's child, so an existing one cannot be handed to `rows`
/// at all. The caller appends it, and what comes back is only ever rows.
pub fn rows_returns_rows_a_caller_can_append_to_test() {
  let existing = ActionRow(id: Some(1), components: buttons(3))
  let mixed =
    list.flatten([
      component.rows(buttons(1)),
      [existing],
      component.rows(buttons(1)),
    ])
  assert mixed
    == [
      ActionRow(id: None, components: buttons(1)),
      existing,
      ActionRow(id: None, components: buttons(1)),
    ]
}

/// Types 9 to 23 are top-level Components V2 elements. They are dropped from
/// the containing list on decode.
pub fn a_components_v2_element_is_dropped_test() {
  assert json.parse("{\"type\":17,\"components\":[]}", component.decoder())
    == Ok(None)
}

/// A create body that spells out its defaults clears things on the next edit.
pub fn button_encodes_without_its_defaults_test() {
  assert encode_child(component.button("go", "Go"))
    == "{\"type\":2,\"style\":1,\"label\":\"Go\",\"custom_id\":\"go\"}"
}

pub fn link_and_premium_buttons_encode_their_own_style_test() {
  assert encode_child(component.link_button("https://example.com", "Go"))
    == "{\"type\":2,\"style\":5,\"label\":\"Go\",\"url\":\"https://example.com\"}"
  assert encode_child(component.premium_button(id.from_string("42")))
    == "{\"type\":2,\"style\":6,\"sku_id\":\"42\"}"
}

pub fn disabled_button_encodes_the_flag_test() {
  let assert Button(..) as base = component.button("go", "Go")
  let value = Button(..base, disabled: True)
  assert encode_child(value)
    == "{\"type\":2,\"style\":1,\"label\":\"Go\",\"custom_id\":\"go\",\"disabled\":true}"
}

pub fn select_encodes_test() {
  let value =
    component.select(
      "pick",
      StringSelect(options: [
        component.SelectOption(
          ..component.option("A", "a"),
          description: Some("first"),
        ),
      ]),
    )
  assert encode_child(value)
    == "{\"type\":3,\"custom_id\":\"pick\",\"options\":"
    <> "[{\"label\":\"A\",\"value\":\"a\",\"description\":\"first\"}]}"
}

pub fn channel_select_encodes_its_types_test() {
  let value =
    component.select(
      "pick",
      ChannelSelect(channel_types: [channel.GuildText], default_channels: [
        id.from_string("9"),
      ]),
    )
  assert encode_child(value)
    == "{\"type\":8,\"custom_id\":\"pick\",\"channel_types\":[0],"
    <> "\"default_values\":[{\"id\":\"9\",\"type\":\"channel\"}]}"
}

pub fn action_row_encodes_its_children_test() {
  assert encode(ActionRow(id: None, components: [component.button("a", "A")]))
    == "{\"type\":1,\"components\":"
    <> "[{\"type\":2,\"style\":1,\"label\":\"A\",\"custom_id\":\"a\"}]}"
}

pub fn decode_encode_round_trip_test() {
  let children = [
    "{\"type\":2,\"style\":4,\"label\":\"Delete\",\"custom_id\":\"delete\"}",
    "{\"type\":2,\"style\":5,\"label\":\"Go\",\"url\":\"https://example.com\"}",
  ]
  list.each(children, fn(text) {
    let assert Ok(value) = parse_child(text)
    assert encode_child(value) == text
  })

  let text =
    "{\"type\":1,\"components\":[{\"type\":2,\"style\":1,\"label\":\"A\",\"custom_id\":\"a\"}]}"
  let assert Ok(value) = parse(text)
  assert encode(value) == text
}

/// The exported style codecs are the copies nothing else exercises, and
/// Discord writes the style as `2` and as `2.0`.
pub fn the_standalone_button_style_codecs_are_wired_together_test() {
  let assert Ok(Some(style)) = json.parse("4", component.button_style_decoder())
  assert style == DangerButton
  assert json.to_string(component.button_style_to_json(style)) == "4"

  assert json.parse("4.0", component.button_style_decoder())
    == Ok(Some(DangerButton))

  assert json.parse("9", component.button_style_decoder()) == Ok(None)
}
