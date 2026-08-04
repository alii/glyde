import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/channel
import glyde/component.{
  ActionButton, ActionRow, Button, ChannelSelect, DangerButton, DefaultChannel,
  DefaultRole, DefaultUser, Icon, LinkButton, MentionableSelect, PremiumButton,
  PrimaryButton, RoleSelect, SecondaryButton, SelectMenu, StringSelect,
  SuccessButton, Text, TextAndIcon, UnknownButtonStyle, UnknownChild,
  UnknownComponent, UserSelect,
}
import glyde/emoji
import glyde/id

fn parse(text: String) -> Result(component.Component, json.DecodeError) {
  json.parse(text, component.decoder())
}

fn encode(value: component.Component) -> String {
  json.to_string(component.to_json(value))
}

/// A button and a select menu are what a row holds, never a top-level entry,
/// so they parse through their own decoder.
fn parse_child(text: String) -> Result(component.RowChild, json.DecodeError) {
  json.parse(text, component.row_child_decoder())
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
/// else's, so it degrades rather than fails. It cannot degrade to an action
/// button: a link style with a `custom_id`, or an action button without one,
/// is a 400 on the way back out. Keeping the payload is re-sendable.
pub fn malformed_button_degrades_rather_than_failing_test() {
  let assert Ok(no_url) =
    parse_child("{\"type\":2,\"style\":5,\"custom_id\":\"x\"}")
  let assert UnknownChild(type_: 2, ..) = no_url
  assert encode_child(no_url) == "{\"custom_id\":\"x\",\"style\":5,\"type\":2}"

  let assert Ok(no_sku) = parse_child("{\"type\":2,\"style\":6}")
  let assert UnknownChild(type_: 2, ..) = no_sku
  assert encode_child(no_sku) == "{\"style\":6,\"type\":2}"

  let assert Ok(no_custom_id) =
    parse_child("{\"type\":2,\"style\":1,\"label\":\"A\"}")
  let assert UnknownChild(type_: 2, ..) = no_custom_id

  // Neither a label nor an emoji is the same class of malformed, and an empty
  // label would go back out as a `"label":""` the payload never carried.
  let assert Ok(says_nothing) =
    parse_child("{\"type\":2,\"style\":1,\"custom_id\":\"x\"}")
  let assert UnknownChild(type_: 2, ..) = says_nothing
  assert encode_child(says_nothing)
    == "{\"custom_id\":\"x\",\"style\":1,\"type\":2}"
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
    #(0, UnknownButtonStyle(0)),
    #(99, UnknownButtonStyle(99)),
  ]
  list.each(styles, fn(row) {
    let #(wire, style) = row
    assert component.button_style_from_int(wire) == style
    assert component.button_style_to_int(style) == wire
  })
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
/// inner one decodes as an unmodelled child with its payload intact.
pub fn a_nested_row_decodes_as_an_unmodelled_child_test() {
  let assert Ok(ActionRow(components: [child], ..)) =
    parse(
      "{\"type\":1,\"components\":[{\"type\":1,\"id\":2,\"components\":[]}]}",
    )
  let assert UnknownChild(type_: 1, ..) = child
  assert encode_child(child) == "{\"components\":[],\"id\":2,\"type\":1}"
}

/// A modal's text input is type 4, a child and not a top-level entry, and one
/// this build does not model. The row keeps it as it arrived.
pub fn a_row_keeps_an_unmodelled_child_test() {
  let text =
    "{\"type\":1,\"components\":[{\"custom_id\":\"name\",\"label\":\"Name\","
    <> "\"style\":1,\"type\":4}]}"
  let assert Ok(value) = parse(text)
  let assert ActionRow(components: [UnknownChild(type_: 4, ..)], ..) = value
  assert encode(value) == text
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
    #(5, UserSelect(default_values: [DefaultUser(id.from_string("1"))])),
    #(6, RoleSelect(default_values: [DefaultRole(id.from_string("1"))])),
    #(7, MentionableSelect(default_values: [DefaultUser(id.from_string("1"))])),
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
      default_values: [DefaultChannel(id.from_string("9"))],
    )
}

/// The select is usually another bot's, so an unknown channel type decodes.
pub fn unknown_channel_type_in_a_select_survives_test() {
  let assert Ok(SelectMenu(kind:, ..)) =
    parse_child("{\"type\":8,\"custom_id\":\"c\",\"channel_types\":[99]}")
  assert kind
    == ChannelSelect(
      channel_types: [channel.UnknownChannelType(99)],
      default_values: [],
    )
}

/// A dropped default would pre-select the wrong things, so this fails instead.
pub fn unknown_default_value_type_is_an_error_test() {
  let assert Error(_) =
    parse_child(
      "{\"type\":5,\"custom_id\":\"c\",\"default_values\":[{\"id\":\"1\",\"type\":\"guild\"}]}",
    )
}

/// Another bot's Components V2 message arrives in your MESSAGE_CREATE.
pub fn unmodelled_component_types_decode_test() {
  let types = [4, 9, 10, 12, 17, 23]
  list.each(types, fn(wire) {
    let assert Ok(value) =
      parse("{\"type\":" <> int.to_string(wire) <> ",\"content\":\"hi\"}")
    let assert UnknownComponent(type_:, ..) = value
    assert type_ == wire
    assert component.component_type_to_int(component.component_type(value))
      == wire
  })
}

/// An unmodelled component keeps its payload, so a bot can echo back a message
/// it did not understand. Key order is normalised: a `Dict` has none.
pub fn unmodelled_component_round_trips_its_payload_test() {
  let assert Ok(value) =
    parse(
      "{\"type\":17,\"accent_color\":16711680,\"spoiler\":false,\"components\":[]}",
    )
  assert encode(value)
    == "{\"accent_color\":16711680,\"components\":[],\"spoiler\":false,\"type\":17}"
}

pub fn unmodelled_component_keeps_nested_values_test() {
  let assert Ok(value) =
    parse(
      "{\"type\":10,\"content\":\"x\",\"nested\":{\"b\":[1,\"two\",null],\"a\":true}}",
    )
  assert encode(value)
    == "{\"content\":\"x\",\"nested\":{\"a\":true,\"b\":[1,\"two\",null]},\"type\":10}"
}

/// The `type` written out comes from the component, not from the payload it
/// was decoded from, so it cannot disagree with `component_type`.
pub fn an_unmodelled_component_writes_the_type_it_reports_test() {
  let assert Ok(payload) = json.parse("{\"content\":\"hi\"}", decode.dynamic)
  let assert Ok(raw) = component.raw_payload(payload)
  assert encode(UnknownComponent(type_: 17, raw:))
    == "{\"content\":\"hi\",\"type\":17}"
}

/// The payload is read once, when it is decoded. An `UnknownComponent` holding
/// something the encoder would silently drop is not a value: the only payload
/// that writes no keys is the empty one, asked for by name.
pub fn a_payload_that_is_not_an_object_is_refused_test() {
  let assert Ok(not_an_object) = json.parse("[1,2]", decode.dynamic)
  assert component.raw_payload(not_an_object) == Error(Nil)

  assert encode(UnknownComponent(type_: 17, raw: component.empty_raw_payload()))
    == "{\"type\":17}"
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
    #(17, component.UnknownComponentType(17)),
  ]
  list.each(table, fn(row) {
    let #(wire, kind) = row
    assert component.component_type_from_int(wire) == kind
    assert component.component_type_to_int(kind) == wire
  })
}

pub fn component_type_matches_the_wire_test() {
  let assert Ok(section) = parse("{\"type\":17,\"components\":[]}")
  assert component.component_type(ActionRow(id: None, components: []))
    == component.ActionRowType
  assert component.component_type(section) == component.UnknownComponentType(17)

  let children = [
    #(component.button("a", "A"), component.ButtonType),
    #(
      component.select("c", StringSelect(options: [])),
      component.StringSelectType,
    ),
    #(
      component.select("c", UserSelect(default_values: [])),
      component.UserSelectType,
    ),
    #(
      component.select("c", RoleSelect(default_values: [])),
      component.RoleSelectType,
    ),
    #(
      component.select("c", MentionableSelect(default_values: [])),
      component.MentionableSelectType,
    ),
    #(
      component.select(
        "c",
        ChannelSelect(channel_types: [], default_values: []),
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
    let assert ActionRow(components:, ..) = row
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

/// Types 9 to 23 are top-level Components V2 elements, and a row around one is
/// a 400. They decode as top-level entries, so `rows` never sees one.
pub fn a_components_v2_element_is_a_top_level_entry_test() {
  let assert Ok(section) = parse("{\"type\":17,\"components\":[]}")
  let assert UnknownComponent(type_: 17, ..) = section
  assert encode(section) == "{\"components\":[],\"type\":17}"
}

/// Being unmodelled is not the same as being top level. A type 2 that failed
/// to decode is still a button, and a button outside a row is a 400.
pub fn rows_packs_an_unmodelled_button_test() {
  let assert Ok(degraded) =
    parse_child("{\"type\":2,\"style\":5,\"custom_id\":\"x\"}")
  let assert UnknownChild(type_: 2, ..) = degraded

  assert component.rows([degraded])
    == [ActionRow(id: None, components: [degraded])]

  let loose = list.flatten([buttons(1), [degraded], buttons(1)])
  assert component.rows(loose) == [ActionRow(id: None, components: loose)]
}

/// A text input is type 4, one per action row, the way a select menu is.
pub fn rows_gives_a_text_input_its_own_row_test() {
  let assert Ok(input) =
    parse_child(
      "{\"type\":4,\"custom_id\":\"name\",\"style\":1,\"label\":\"Name\"}",
    )
  let assert UnknownChild(type_: 4, ..) = input

  let mixed = list.flatten([buttons(2), [input], buttons(1)])
  assert row_widths(component.rows(mixed)) == [2, 1, 1]
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
      ChannelSelect(channel_types: [channel.GuildText], default_values: [
        DefaultChannel(id.from_string("9")),
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
  let assert Ok(style) = json.parse("4", component.button_style_decoder())
  assert style == DangerButton
  assert json.to_string(component.button_style_to_json(style)) == "4"

  assert json.parse("4.0", component.button_style_decoder()) == Ok(DangerButton)

  let assert Ok(unknown) = json.parse("9", component.button_style_decoder())
  assert unknown == UnknownButtonStyle(9)
  assert json.to_string(component.button_style_to_json(unknown)) == "9"
}
