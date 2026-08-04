import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/flags
import glyde/id
import glyde/user

fn parse(text: String) -> Result(user.User, json.DecodeError) {
  json.parse(text, user.decoder())
}

fn parse_me(text: String) -> Result(user.CurrentUser, json.DecodeError) {
  json.parse(text, user.current_user_decoder())
}

pub fn decodes_a_full_user_test() {
  let assert Ok(account) =
    parse(
      "{\"id\":\"80351110224678912\",\"username\":\"nelly\",\"discriminator\":\"0\",\"global_name\":\"Nelly\",\"avatar\":\"8342729096ea3675442027381ff50dfe\",\"bot\":false,\"system\":false,\"banner\":\"06c16474723fe537c283b8efa61a30c8\",\"accent_color\":16711680,\"locale\":\"en-US\",\"flags\":64,\"public_flags\":64,\"premium_type\":1}",
    )
  assert id.to_string(account.id) == "80351110224678912"
  assert account.username == "nelly"
  assert account.discriminator == "0"
  assert account.global_name == Some("Nelly")
  assert account.avatar == Some("8342729096ea3675442027381ff50dfe")
  assert account.bot == False
  assert account.accent_color == Some(16_711_680)
  assert account.public_flags == Some(flags.from_int(64))
}

/// `locale`, `flags` and `premium_type` need the `identify` scope, so they are
/// on `CurrentUser` and no message author can carry them.
pub fn the_identify_scoped_fields_are_the_current_users_test() {
  let assert Ok(me) =
    parse_me(
      "{\"id\":\"1\",\"username\":\"glyde\",\"locale\":\"en-US\",\"flags\":64,\"public_flags\":64,\"premium_type\":1}",
    )
  assert me.locale == Some("en-US")
  assert me.flags == Some(flags.from_int(64))
  assert me.premium_type == Some(user.NitroClassic)
  assert me.user.public_flags == Some(flags.from_int(64))
}

/// A webhook author carries three keys, so requiring any other one fails the
/// whole message.
pub fn decodes_a_webhook_author_test() {
  let assert Ok(author) =
    parse("{\"id\":\"1\",\"username\":\"Captain Hook\",\"avatar\":null}")
  assert author.username == "Captain Hook"
  assert author.discriminator == "0"
  assert author.global_name == None
  assert author.avatar == None
  assert author.bot == False
  assert author.public_flags == None
}

/// An id on its own is still a user.
pub fn decodes_an_id_and_nothing_else_test() {
  let assert Ok(account) = parse("{\"id\":\"1\"}")
  assert account.username == ""
  assert account.discriminator == "0"
  assert account.system == False
  assert account.avatar_decoration == None
}

pub fn requires_an_id_test() {
  let assert Error(_) = parse("{\"username\":\"nelly\"}")
}

/// Absent and null are different keys on the wire and the same value here.
pub fn absent_and_null_both_collapse_to_none_test() {
  let cases = [
    #("{\"id\":\"1\"}", None),
    #("{\"id\":\"1\",\"global_name\":null}", None),
    #("{\"id\":\"1\",\"global_name\":\"Nelly\"}", Some("Nelly")),
  ]
  list.each(cases, fn(row) {
    let #(text, expected) = row
    let assert Ok(account) = parse(text)
    assert account.global_name == expected
  })
}

/// Discord omits a false boolean rather than sending it.
pub fn a_missing_bool_is_false_test() {
  let assert Ok(plain) = parse("{\"id\":\"1\"}")
  assert plain.bot == False
  assert plain.system == False

  let assert Ok(robot) = parse("{\"id\":\"1\",\"bot\":true,\"system\":true}")
  assert robot.bot == True
  assert robot.system == True
}

/// Discord does not document a null boolean, and false beats failing.
pub fn a_null_bool_is_false_test() {
  let assert Ok(account) = parse("{\"id\":\"1\",\"bot\":null}")
  assert account.bot == False
}

pub fn user_flag_bits_test() {
  let table = [
    #(user.Staff, 1),
    #(user.Partner, 2),
    #(user.Hypesquad, 4),
    #(user.BugHunterLevel1, 8),
    #(user.HypesquadOnlineHouse1, 64),
    #(user.HypesquadOnlineHouse2, 128),
    #(user.HypesquadOnlineHouse3, 256),
    #(user.PremiumEarlySupporter, 512),
    #(user.TeamPseudoUser, 1024),
    #(user.BugHunterLevel2, 16_384),
    #(user.VerifiedBot, 65_536),
    #(user.VerifiedDeveloper, 131_072),
    #(user.CertifiedModerator, 262_144),
    #(user.BotHttpInteractions, 524_288),
    #(user.ActiveDeveloper, 4_194_304),
  ]
  list.each(table, fn(row) {
    let #(flag, bit) = row
    assert user.has_flag(flags.from_int(bit), flag) == True
    assert user.has_flag(flags.from_int(0), flag) == False
    // Catches a bit value copied from the row above.
    list.each(table, fn(other) {
      case other.1 == bit {
        True -> Nil
        False -> {
          assert user.has_flag(flags.from_int(bit), other.0) == False
          Nil
        }
      }
    })
  })
}

/// A bit Discord adds later has to survive a decode and re-encode.
pub fn unknown_flag_bits_survive_test() {
  let assert Ok(me) = parse_me("{\"id\":\"1\",\"flags\":1073741825}")
  let assert Some(flags) = me.flags
  assert flags.to_int(flags) == 1_073_741_825
  assert user.has_flag(flags, user.Staff) == True
}

pub fn flags_are_optional_test() {
  let assert Ok(without) = parse_me("{\"id\":\"1\"}")
  assert without.flags == None
  assert without.user.public_flags == None

  let assert Ok(with) =
    parse_me("{\"id\":\"1\",\"flags\":0,\"public_flags\":4}")
  assert with.flags == Some(flags.from_int(0))
  assert with.user.public_flags == Some(flags.from_int(4))
}

pub fn premium_type_round_trips_test() {
  let table = [
    #(0, user.NoPremium),
    #(1, user.NitroClassic),
    #(2, user.Nitro),
    #(3, user.NitroBasic),
  ]
  list.each(table, fn(row) {
    let #(wire, variant) = row
    assert user.premium_type_from_int(wire) == Some(variant)
    assert user.premium_type_to_int(variant) == wire
    assert json.to_string(user.premium_type_to_json(variant)) == int_text(wire)
  })
  assert user.premium_type_from_int(4) == None
  assert user.premium_type_from_int(99) == None
}

fn int_text(value: Int) -> String {
  json.to_string(json.int(value))
}

/// A value this build has no name for decodes as `None` rather than failing.
pub fn an_unmodelled_premium_type_tolerated_test() {
  let assert Ok(me) = parse_me("{\"id\":\"1\",\"premium_type\":7}")
  assert me.premium_type == None
}

/// The JSON key is `avatar_decoration_data`, which is not what the field is
/// called.
pub fn avatar_decoration_reads_the_data_key_test() {
  let assert Ok(account) =
    parse(
      "{\"id\":\"1\",\"avatar_decoration_data\":{\"asset\":\"a_fed43ab12698df65902ba06727e20c0e\",\"sku_id\":\"1144058844004233369\"}}",
    )
  let assert Some(decoration) = account.avatar_decoration
  assert decoration.asset == "a_fed43ab12698df65902ba06727e20c0e"
  assert id.to_string(decoration.sku_id) == "1144058844004233369"

  let assert Ok(wrong_key) =
    parse("{\"id\":\"1\",\"avatar_decoration\":{\"asset\":\"x\"}}")
  assert wrong_key.avatar_decoration == None
}

pub fn avatar_decoration_can_be_null_test() {
  let assert Ok(account) =
    parse("{\"id\":\"1\",\"avatar_decoration_data\":null}")
  assert account.avatar_decoration == None
}

/// Both keys of the decoration are required, and a user rides along with
/// nearly every event, so a change to it must not sink all of them.
pub fn a_decoration_of_the_wrong_shape_does_not_sink_the_user_test() {
  let shapes = [
    "{\"id\":\"1\",\"avatar_decoration_data\":{\"asset\":\"a\"}}",
    "{\"id\":\"1\",\"avatar_decoration_data\":{}}",
    "{\"id\":\"1\",\"avatar_decoration_data\":\"nope\"}",
  ]
  list.each(shapes, fn(body) {
    let assert Ok(account) = parse(body)
    assert account.avatar_decoration == None
    assert id.to_string(account.id) == "1"
  })
}

/// Discord writes the same integer field as `2` and as `2.0`.
pub fn a_whole_number_written_as_a_float_decodes_test() {
  let assert Ok(account) = parse("{\"id\":\"1\",\"accent_color\":16711680.0}")
  assert account.accent_color == Some(16_711_680)
}

pub fn a_fractional_colour_is_rejected_test() {
  let assert Error(_) = parse("{\"id\":\"1\",\"accent_color\":1.5}")
}

/// The three extra keys sit beside the user's own, not nested under one.
pub fn current_user_reads_the_same_object_test() {
  let assert Ok(me) =
    json.parse(
      "{\"id\":\"1\",\"username\":\"glyde\",\"mfa_enabled\":true,\"verified\":true,\"email\":\"bot@example.com\"}",
      user.current_user_decoder(),
    )
  assert me.user.username == "glyde"
  assert me.mfa_enabled == True
  assert me.verified == Some(True)
  assert me.email == Some("bot@example.com")
}

/// A bot token has no `email` scope, so both keys are missing.
pub fn current_user_without_an_email_scope_test() {
  let assert Ok(me) =
    json.parse(
      "{\"id\":\"1\",\"username\":\"glyde\"}",
      user.current_user_decoder(),
    )
  assert me.mfa_enabled == False
  assert me.verified == None
  assert me.email == None
}

pub fn decodes_inside_a_larger_payload_test() {
  let assert Ok(author) =
    json.parse(
      "{\"content\":\"hi\",\"author\":{\"id\":\"2\",\"username\":\"a\"}}",
      decode.at(["author"], user.decoder()),
    )
  assert id.to_string(author.id) == "2"
}

/// Global name first, then the username. `None` for the `""` the decoder puts
/// in when there is no `username` key, which is what a webhook author sends.
pub fn display_name_prefers_the_global_name_test() {
  let table = [
    #(
      "{\"id\":\"1\",\"username\":\"name\",\"global_name\":\"Global\"}",
      Some("Global"),
    ),
    #("{\"id\":\"1\",\"username\":\"name\",\"global_name\":null}", Some("name")),
    #("{\"id\":\"1\",\"username\":\"name\"}", Some("name")),
    #("{\"id\":\"1\"}", None),
  ]
  list.each(table, fn(row) {
    let #(text, expected) = row
    let assert Ok(account) = parse(text)
    assert user.display_name(account) == expected
  })
}
