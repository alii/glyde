//// Every endpoint as one row: the method, the bytes of the target, the
//// rate-limit template and the major parameter.

import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import glyde/application_command
import glyde/channel
import glyde/gateway_info
import glyde/guild

import glyde/emoji
import glyde/id
import glyde/interaction
import glyde/member
import glyde/mentions
import glyde/message
import glyde/role
import glyde/user
import glyde/webhook

import glyde/rest
import glyde/rest/body.{type Body}
import glyde/rest/headers
import glyde/rest/limiter
import glyde/rest/query
import glyde/rest/route
import glyde/rest/seg

const channel_text: String = "41771983423143937"

const message_text: String = "308994132968210433"

const guild_text: String = "197038439483310086"

const user_text: String = "80351110224678912"

const role_text: String = "41771983423143936"

const overwrite_text: String = "155117677105512449"

const emoji_text: String = "41771983429993937"

const application_text: String = "1234567890123456789"

const command_text: String = "987654321098765432"

const interaction_text: String = "846092147101974528"

/// Only unreserved characters, so the expected paths below stay readable.
const interaction_token: String = "aW50ZXJhY3Rpb24udG9rZW4"

const webhook_text: String = "223704706495545344"

const webhook_token: String = "3d89bb7572e0fb30d8128367b3b1b44f"

const thread_text: String = "670094564427005956"

fn channel_id() -> id.ChannelId {
  id.from_string(channel_text)
}

fn message_id() -> id.MessageId {
  id.from_string(message_text)
}

fn guild_id() -> id.GuildId {
  id.from_string(guild_text)
}

fn user_id() -> id.UserId {
  id.from_string(user_text)
}

fn role_id() -> id.RoleId {
  id.from_string(role_text)
}

fn overwrite_id() -> id.OverwriteId {
  id.from_string(overwrite_text)
}

fn application_id() -> id.ApplicationId {
  id.from_string(application_text)
}

fn command_id() -> id.CommandId {
  id.from_string(command_text)
}

fn interaction_id() -> id.InteractionId {
  id.from_string(interaction_text)
}

fn webhook_id() -> id.WebhookId {
  id.from_string(webhook_text)
}

fn thread_id() -> id.ChannelId {
  id.from_string(thread_text)
}

fn responder() -> interaction.Responder {
  interaction.responder(
    interaction: interaction_id(),
    application: application_id(),
    token: interaction.interaction_token(interaction_token),
  )
}

fn webhook_credential() -> webhook.Credential {
  webhook.credential(webhook_id(), webhook_token)
}

fn config() -> rest.Config {
  rest.config(rest.bot("MTk4NjIyNDgzNDcxOTI1MjQ4.s3cret"))
}

/// For the hand-rolled calls below, where the routing is the point.
fn nothing() -> Decoder(Nil) {
  decode.success(Nil)
}

fn payload() -> Body {
  body.json([#("content", json.string("hi"))])
}

/// The command routes take the payload rather than a body, so the rows below
/// need one. The smallest command there is: the routing is the point.
fn slash_command() -> application_command.CreateApplicationCommand {
  application_command.new_chat_input(name: "ping", description: "pong")
}

fn global_slash_command() -> application_command.GlobalCommand {
  application_command.global(slash_command())
}

/// A reaction emoji whose encoding is short enough to read in the table.
fn fire() -> message.ReactionEmoji {
  message.unicode_emoji("🔥")
}

const fire_encoded: String = "%F0%9F%94%A5"

type Row {
  Row(
    name: String,
    made: Made,
    method: http.Method,
    /// Path and query as they go on the wire, without the `/api/v10` prefix.
    target: String,
    template: String,
    major: route.Major,
  )
}

/// A row keeps this rather than the `Call`, because one list cannot hold a
/// `Call(GatewayBot)` next to a `Call(Nil)`.
type Made {
  Made(path: String, query: Option(String), route: route.Route)
}

/// The only place a call's response type has to be known.
fn row(
  name: String,
  call: rest.Call(a),
  method: http.Method,
  target: String,
  template: String,
  major: route.Major,
) -> Row {
  let request = rest.request(config(), call)
  let made =
    Made(path: request.path, query: request.query, route: rest.route(call))
  Row(name:, made:, method:, target:, template:, major:)
}

fn target(row: Row) -> String {
  let path = string.replace(row.made.path, each: "/api/v10", with: "")
  case row.made.query {
    None -> path
    Some(text) -> path <> "?" <> text
  }
}

fn rows() -> List(Row) {
  list.flatten([
    message_rows(),
    reaction_rows(),
    pin_and_typing_rows(),
    channel_rows(),
    thread_rows(),
    guild_rows(),
    member_rows(),
    role_rows(),
    user_rows(),
    command_rows(),
    interaction_rows(),
    webhook_rows(),
    gateway_info_rows(),
  ])
}

fn messages_path() -> String {
  "/channels/" <> channel_text <> "/messages"
}

fn one_message_path() -> String {
  messages_path() <> "/" <> message_text
}

fn message_rows() -> List(Row) {
  [
    row(
      "1 get messages",
      message.list(channel_id(), cursor: None, limit: None),
      http.Get,
      messages_path(),
      "/channels/{channel.id}/messages",
      route.ChannelMajor(channel_text),
    ),
    row(
      "2 get message",
      message.get(channel_id(), message_id()),
      http.Get,
      one_message_path(),
      "/channels/{channel.id}/messages/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "3 create message",
      message.send(channel_id(), message.new()),
      http.Post,
      messages_path(),
      "/channels/{channel.id}/messages",
      route.ChannelMajor(channel_text),
    ),
    row(
      "4 edit message",
      message.edit_id(
        channel_id(),
        message_id(),
        message.new_edit(mentions.none()),
      ),
      http.Patch,
      one_message_path(),
      "/channels/{channel.id}/messages/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "5 delete message",
      message.delete_id(channel_id(), message_id()),
      http.Delete,
      one_message_path(),
      "/channels/{channel.id}/messages/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "6 bulk delete",
      message.bulk_delete(channel_id(), []),
      http.Post,
      messages_path() <> "/bulk-delete",
      "/channels/{channel.id}/messages/bulk-delete",
      route.ChannelMajor(channel_text),
    ),
  ]
}

fn reactions_path() -> String {
  one_message_path() <> "/reactions"
}

/// The five routes that name an emoji collapse to this template, so the emoji
/// never earns a bucket of its own.
const reaction_template: String = "/channels/{channel.id}/messages/{id}/reactions/{reaction}"

fn reaction_rows() -> List(Row) {
  [
    row(
      "7 create reaction",
      message.react_id(channel_id(), message_id(), fire()),
      http.Put,
      reactions_path() <> "/" <> fire_encoded <> "/@me",
      reaction_template,
      route.ChannelMajor(channel_text),
    ),
    row(
      "8 delete own reaction",
      message.unreact_id(channel_id(), message_id(), fire()),
      http.Delete,
      reactions_path() <> "/" <> fire_encoded <> "/@me",
      reaction_template,
      route.ChannelMajor(channel_text),
    ),
    row(
      "9 delete user reaction",
      message.remove_reaction_id(channel_id(), message_id(), fire(), user_id()),
      http.Delete,
      reactions_path() <> "/" <> fire_encoded <> "/" <> user_text,
      reaction_template,
      route.ChannelMajor(channel_text),
    ),
    row(
      "10 get reactions",
      message.reactions_id(
        channel_id(),
        message_id(),
        fire(),
        type_: None,
        after: None,
        limit: None,
      ),
      http.Get,
      reactions_path() <> "/" <> fire_encoded,
      reaction_template,
      route.ChannelMajor(channel_text),
    ),
    row(
      "11 delete emoji reactions",
      message.clear_emoji_reactions_id(channel_id(), message_id(), fire()),
      http.Delete,
      reactions_path() <> "/" <> fire_encoded,
      reaction_template,
      route.ChannelMajor(channel_text),
    ),
    row(
      "12 delete all reactions",
      message.clear_reactions_id(channel_id(), message_id()),
      http.Delete,
      reactions_path(),
      "/channels/{channel.id}/messages/{id}/reactions",
      route.ChannelMajor(channel_text),
    ),
  ]
}

fn pins_path() -> String {
  messages_path() <> "/pins"
}

fn pin_and_typing_rows() -> List(Row) {
  [
    row(
      "13 get pins",
      message.pins(channel_id(), before: None, limit: None),
      http.Get,
      pins_path(),
      "/channels/{channel.id}/messages/pins",
      route.ChannelMajor(channel_text),
    ),
    row(
      "14 pin message",
      message.pin_id(channel_id(), message_id()),
      http.Put,
      pins_path() <> "/" <> message_text,
      "/channels/{channel.id}/messages/pins/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "15 unpin message",
      message.unpin_id(channel_id(), message_id()),
      http.Delete,
      pins_path() <> "/" <> message_text,
      "/channels/{channel.id}/messages/pins/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "16 trigger typing",
      channel.typing(channel_id()),
      http.Post,
      "/channels/" <> channel_text <> "/typing",
      "/channels/{channel.id}/typing",
      route.ChannelMajor(channel_text),
    ),
  ]
}

fn channel_path() -> String {
  "/channels/" <> channel_text
}

fn channel_rows() -> List(Row) {
  [
    row(
      "17 get channel",
      channel.get(channel_id()),
      http.Get,
      channel_path(),
      "/channels/{channel.id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "18 edit channel",
      channel.edit(channel_id(), channel.edit_guild_channel()),
      http.Patch,
      channel_path(),
      "/channels/{channel.id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "19 delete channel",
      channel.delete(channel_id()),
      http.Delete,
      channel_path(),
      "/channels/{channel.id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "20 edit channel permissions",
      channel.set_permission(channel_id(), channel.role_overwrite(role_id())),
      http.Put,
      channel_path() <> "/permissions/" <> role_text,
      "/channels/{channel.id}/permissions/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "21 delete channel permission",
      channel.clear_permission(channel_id(), overwrite_id()),
      http.Delete,
      channel_path() <> "/permissions/" <> overwrite_text,
      "/channels/{channel.id}/permissions/{id}",
      route.ChannelMajor(channel_text),
    ),
  ]
}

fn thread_members_path() -> String {
  channel_path() <> "/thread-members"
}

fn thread_rows() -> List(Row) {
  [
    row(
      "24 start thread from message",
      channel.start_thread_from_message(
        channel_id(),
        message_id(),
        channel.create_thread_from_message("t"),
      ),
      http.Post,
      one_message_path() <> "/threads",
      "/channels/{channel.id}/messages/{id}/threads",
      route.ChannelMajor(channel_text),
    ),
    row(
      "25 start thread",
      channel.start_thread(
        channel_id(),
        channel.create_thread("t", channel.PublicThread),
      ),
      http.Post,
      channel_path() <> "/threads",
      "/channels/{channel.id}/threads",
      route.ChannelMajor(channel_text),
    ),
    row(
      "26 join thread",
      channel.join_thread(channel_id()),
      http.Put,
      thread_members_path() <> "/@me",
      "/channels/{channel.id}/thread-members/@me",
      route.ChannelMajor(channel_text),
    ),
    row(
      "27 leave thread",
      channel.leave_thread(channel_id()),
      http.Delete,
      thread_members_path() <> "/@me",
      "/channels/{channel.id}/thread-members/@me",
      route.ChannelMajor(channel_text),
    ),
    row(
      "28 add thread member",
      channel.add_thread_member(channel_id(), user_id()),
      http.Put,
      thread_members_path() <> "/" <> user_text,
      "/channels/{channel.id}/thread-members/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "29 remove thread member",
      channel.remove_thread_member(channel_id(), user_id()),
      http.Delete,
      thread_members_path() <> "/" <> user_text,
      "/channels/{channel.id}/thread-members/{id}",
      route.ChannelMajor(channel_text),
    ),
    row(
      "31 public archived threads",
      channel.public_archived_threads(channel_id(), before: None, limit: None),
      http.Get,
      channel_path() <> "/threads/archived/public",
      "/channels/{channel.id}/threads/archived/public",
      route.ChannelMajor(channel_text),
    ),
    row(
      "32 private archived threads",
      channel.private_archived_threads(channel_id(), before: None, limit: None),
      http.Get,
      channel_path() <> "/threads/archived/private",
      "/channels/{channel.id}/threads/archived/private",
      route.ChannelMajor(channel_text),
    ),
  ]
}

fn guild_path() -> String {
  "/guilds/" <> guild_text
}

fn guild_rows() -> List(Row) {
  [
    row(
      "22 get guild channels",
      guild.channels(guild_id()),
      http.Get,
      guild_path() <> "/channels",
      "/guilds/{guild.id}/channels",
      route.GuildMajor(guild_text),
    ),
    row(
      "23 create guild channel",
      guild.create_channel(guild_id(), channel.create_channel("test")),
      http.Post,
      guild_path() <> "/channels",
      "/guilds/{guild.id}/channels",
      route.GuildMajor(guild_text),
    ),
    row(
      "30 active threads",
      guild.active_threads(guild_id()),
      http.Get,
      guild_path() <> "/threads/active",
      "/guilds/{guild.id}/threads/active",
      route.GuildMajor(guild_text),
    ),
    row(
      "33 get guild",
      guild.get(guild_id(), with_counts: True),
      http.Get,
      guild_path() <> "?with_counts=true",
      "/guilds/{guild.id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "34 get bans",
      guild.bans(guild_id(), cursor: None, limit: None),
      http.Get,
      guild_path() <> "/bans",
      "/guilds/{guild.id}/bans",
      route.GuildMajor(guild_text),
    ),
    row(
      "35 get ban",
      guild.ban_for(guild_id(), user_id()),
      http.Get,
      guild_path() <> "/bans/" <> user_text,
      "/guilds/{guild.id}/bans/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "36 create ban",
      guild.ban(guild_id(), user_id(), member.create_ban()),
      http.Put,
      guild_path() <> "/bans/" <> user_text,
      "/guilds/{guild.id}/bans/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "37 remove ban",
      guild.unban(guild_id(), user_id()),
      http.Delete,
      guild_path() <> "/bans/" <> user_text,
      "/guilds/{guild.id}/bans/{id}",
      route.GuildMajor(guild_text),
    ),
  ]
}

fn members_path() -> String {
  guild_path() <> "/members"
}

fn member_rows() -> List(Row) {
  [
    row(
      "38 get members",
      guild.members(guild_id(), after: None, limit: None),
      http.Get,
      members_path(),
      "/guilds/{guild.id}/members",
      route.GuildMajor(guild_text),
    ),
    row(
      "39 get member",
      guild.member(guild_id(), user_id()),
      http.Get,
      members_path() <> "/" <> user_text,
      "/guilds/{guild.id}/members/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "40 search members",
      guild.search_members(guild_id(), query: "ali", limit: None),
      http.Get,
      members_path() <> "/search?query=ali",
      "/guilds/{guild.id}/members/search",
      route.GuildMajor(guild_text),
    ),
    row(
      "41 edit member",
      guild.edit_member(guild_id(), user_id(), member.edit_guild_member()),
      http.Patch,
      members_path() <> "/" <> user_text,
      "/guilds/{guild.id}/members/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "42 edit current member",
      guild.edit_me(guild_id(), member.edit_current_member()),
      http.Patch,
      members_path() <> "/@me",
      "/guilds/{guild.id}/members/@me",
      route.GuildMajor(guild_text),
    ),
    row(
      "43 kick member",
      guild.kick(guild_id(), user_id()),
      http.Delete,
      members_path() <> "/" <> user_text,
      "/guilds/{guild.id}/members/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "44 add member role",
      guild.add_role(guild_id(), user_id(), role_id()),
      http.Put,
      members_path() <> "/" <> user_text <> "/roles/" <> role_text,
      "/guilds/{guild.id}/members/{id}/roles/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "45 remove member role",
      guild.remove_role(guild_id(), user_id(), role_id()),
      http.Delete,
      members_path() <> "/" <> user_text <> "/roles/" <> role_text,
      "/guilds/{guild.id}/members/{id}/roles/{id}",
      route.GuildMajor(guild_text),
    ),
  ]
}

fn roles_path() -> String {
  guild_path() <> "/roles"
}

fn role_rows() -> List(Row) {
  [
    row(
      "46 get roles",
      guild.roles(guild_id()),
      http.Get,
      roles_path(),
      "/guilds/{guild.id}/roles",
      route.GuildMajor(guild_text),
    ),
    row(
      "47 get role",
      guild.role(guild_id(), role_id()),
      http.Get,
      roles_path() <> "/" <> role_text,
      "/guilds/{guild.id}/roles/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "48 create role",
      guild.create_role(guild_id(), role.create_role()),
      http.Post,
      roles_path(),
      "/guilds/{guild.id}/roles",
      route.GuildMajor(guild_text),
    ),
    row(
      "49 edit role",
      guild.edit_role(guild_id(), role_id(), role.edit_role()),
      http.Patch,
      roles_path() <> "/" <> role_text,
      "/guilds/{guild.id}/roles/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "50 delete role",
      guild.delete_role(guild_id(), role_id()),
      http.Delete,
      roles_path() <> "/" <> role_text,
      "/guilds/{guild.id}/roles/{id}",
      route.GuildMajor(guild_text),
    ),
  ]
}

fn user_rows() -> List(Row) {
  [
    row(
      "51 get current user",
      user.me(),
      http.Get,
      "/users/@me",
      "/users/@me",
      route.NoMajor,
    ),
    row(
      "52 get user",
      user.get(user_id()),
      http.Get,
      "/users/" <> user_text,
      "/users/{id}",
      route.NoMajor,
    ),
    row(
      "53 create dm",
      channel.open_dm(user_id()),
      http.Post,
      "/users/@me/channels",
      "/users/@me/channels",
      route.NoMajor,
    ),
    row(
      "54 get current user guilds",
      guild.mine(cursor: None, limit: None, with_counts: False),
      http.Get,
      "/users/@me/guilds?with_counts=false",
      "/users/@me/guilds",
      route.NoMajor,
    ),
    row(
      "55 get current user guild member",
      guild.my_member(guild_id()),
      http.Get,
      "/users/@me/guilds/" <> guild_text <> "/member",
      "/users/@me/guilds/{id}/member",
      route.NoMajor,
    ),
    row(
      "56 leave guild",
      guild.leave(guild_id()),
      http.Delete,
      "/users/@me/guilds/" <> guild_text,
      "/users/@me/guilds/{id}",
      route.NoMajor,
    ),
  ]
}

fn global_commands_path() -> String {
  "/applications/" <> application_text <> "/commands"
}

fn guild_commands_path() -> String {
  "/applications/"
  <> application_text
  <> "/guilds/"
  <> guild_text
  <> "/commands"
}

const global_commands_template: String = "/applications/{id}/commands"

const guild_commands_template: String = "/applications/{id}/guilds/{guild.id}/commands"

fn command_rows() -> List(Row) {
  [
    row(
      "57 get global commands",
      application_command.get_global_commands(
        application_id(),
        with_localizations: False,
      ),
      http.Get,
      global_commands_path() <> "?with_localizations=false",
      global_commands_template,
      route.NoMajor,
    ),
    row(
      "58 create global command",
      application_command.create_global_command(
        application_id(),
        global_slash_command(),
      ),
      http.Post,
      global_commands_path(),
      global_commands_template,
      route.NoMajor,
    ),
    row(
      "59 get global command",
      application_command.get_global_command(application_id(), command_id()),
      http.Get,
      global_commands_path() <> "/" <> command_text,
      global_commands_template <> "/{id}",
      route.NoMajor,
    ),
    row(
      "60 edit global command",
      application_command.edit_global_command(
        application_id(),
        command_id(),
        application_command.edit_global(),
      ),
      http.Patch,
      global_commands_path() <> "/" <> command_text,
      global_commands_template <> "/{id}",
      route.NoMajor,
    ),
    row(
      "61 delete global command",
      application_command.delete_global_command(application_id(), command_id()),
      http.Delete,
      global_commands_path() <> "/" <> command_text,
      global_commands_template <> "/{id}",
      route.NoMajor,
    ),
    row(
      "62 set global commands",
      application_command.set_global_commands(application_id(), [
        global_slash_command(),
      ]),
      http.Put,
      global_commands_path(),
      global_commands_template,
      route.NoMajor,
    ),
    row(
      "63 get guild commands",
      application_command.get_guild_commands(
        application_id(),
        guild_id(),
        with_localizations: True,
      ),
      http.Get,
      guild_commands_path() <> "?with_localizations=true",
      guild_commands_template,
      route.GuildMajor(guild_text),
    ),
    row(
      "64 create guild command",
      application_command.create_guild_command(
        application_id(),
        guild_id(),
        slash_command(),
      ),
      http.Post,
      guild_commands_path(),
      guild_commands_template,
      route.GuildMajor(guild_text),
    ),
    row(
      "65 get guild command",
      application_command.get_guild_command(
        application_id(),
        guild_id(),
        command_id(),
      ),
      http.Get,
      guild_commands_path() <> "/" <> command_text,
      guild_commands_template <> "/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "66 edit guild command",
      application_command.edit_guild_command(
        application_id(),
        guild_id(),
        command_id(),
        application_command.edit(),
      ),
      http.Patch,
      guild_commands_path() <> "/" <> command_text,
      guild_commands_template <> "/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "67 delete guild command",
      application_command.delete_guild_command(
        application_id(),
        guild_id(),
        command_id(),
      ),
      http.Delete,
      guild_commands_path() <> "/" <> command_text,
      guild_commands_template <> "/{id}",
      route.GuildMajor(guild_text),
    ),
    row(
      "68 set guild commands",
      application_command.set_guild_commands(application_id(), guild_id(), [
        slash_command(),
      ]),
      http.Put,
      guild_commands_path(),
      guild_commands_template,
      route.GuildMajor(guild_text),
    ),
  ]
}

fn interaction_rows() -> List(Row) {
  [
    row(
      "69 interaction callback",
      interaction.callback(responder(), payload()),
      http.Post,
      "/interactions/"
        <> interaction_text
        <> "/"
        <> interaction_token
        <> "/callback",
      "/interactions/{id}/{opaque}/callback",
      route.NoMajor,
    ),
  ]
}

fn webhook_path() -> String {
  "/webhooks/" <> webhook_text <> "/" <> webhook_token
}

const webhook_template: String = "/webhooks/{webhook.id}/{webhook.token}"

fn webhook_major() -> route.Major {
  route.WebhookMajor(webhook_text, route.webhook_token(Some(webhook_token)))
}

fn webhook_rows() -> List(Row) {
  [
    row(
      "70 get original",
      webhook.get_original_message(webhook_credential(), thread: None),
      http.Get,
      webhook_path() <> "/messages/@original",
      webhook_template <> "/messages/@original",
      webhook_major(),
    ),
    row(
      "71 edit original",
      webhook.edit_original_message(
        webhook_credential(),
        payload(),
        thread: None,
      ),
      http.Patch,
      webhook_path() <> "/messages/@original",
      webhook_template <> "/messages/@original",
      webhook_major(),
    ),
    row(
      "72 delete original",
      webhook.delete_original_message(webhook_credential(), thread: None),
      http.Delete,
      webhook_path() <> "/messages/@original",
      webhook_template <> "/messages/@original",
      webhook_major(),
    ),
    row(
      "73 execute webhook",
      webhook.execute(webhook_credential(), payload(), thread: None),
      http.Post,
      webhook_path(),
      webhook_template,
      webhook_major(),
    ),
    row(
      "74 get webhook message",
      webhook.get_message(webhook_credential(), message_id(), thread: None),
      http.Get,
      webhook_path() <> "/messages/" <> message_text,
      webhook_template <> "/messages/{id}",
      webhook_major(),
    ),
    row(
      "75 edit webhook message",
      webhook.edit_message(
        webhook_credential(),
        message_id(),
        payload(),
        thread: None,
      ),
      http.Patch,
      webhook_path() <> "/messages/" <> message_text,
      webhook_template <> "/messages/{id}",
      webhook_major(),
    ),
    row(
      "76 delete webhook message",
      webhook.delete_message(webhook_credential(), message_id(), thread: None),
      http.Delete,
      webhook_path() <> "/messages/" <> message_text,
      webhook_template <> "/messages/{id}",
      webhook_major(),
    ),
  ]
}

fn gateway_info_rows() -> List(Row) {
  [
    row(
      "77 get gateway",
      gateway_info.get(),
      http.Get,
      "/gateway",
      "/gateway",
      route.NoMajor,
    ),
    row(
      "78 get gateway bot",
      gateway_info.get_bot(),
      http.Get,
      "/gateway/bot",
      "/gateway/bot",
      route.NoMajor,
    ),
  ]
}

/// The row's name is compared too, so a failure names the endpoint.
pub fn every_route_test() {
  list.each(rows(), fn(row) {
    let found = row.made.route
    assert #(row.name, route.method(found), target(row), route.template(found))
      == #(row.name, row.method, row.target, row.template)
    assert #(row.name, route.same_major(route.major(found), row.major))
      == #(row.name, True)
  })
}

/// The count and the name-uniqueness together catch a missing row and a row
/// pasted twice.
pub fn the_table_holds_seventy_eight_routes_test() {
  assert list.length(rows()) == 78

  let names = list.map(rows(), fn(row) { row.name })
  assert set.size(set.from_list(names)) == 78
}

/// An unversioned path routes to v6, which is deprecated.
pub fn every_route_is_versioned_test() {
  list.each(rows(), fn(row) {
    assert string.starts_with(row.made.path, "/api/v10/")
  })
}

/// A call with no parameters must not end in a bare `?`.
pub fn no_route_emits_an_empty_query_test() {
  list.each(rows(), fn(row) {
    assert row.made.query != Some("")
  })
}

/// Anything else classified `Unbound` would stop being rate limited at all.
pub fn only_the_callback_is_unbound_test() {
  list.each(rows(), fn(row) {
    let expected = row.name == "69 interaction callback"
    assert #(row.name, route.unbound(row.made.route)) == #(row.name, expected)
  })
}

/// Discord rejects two cursors on one request, so the type carries one.
pub fn a_message_cursor_emits_exactly_one_parameter_test() {
  let cursors = [
    #(None, ""),
    #(Some(message.Around(message_id())), "?around=" <> message_text),
    #(Some(message.Before(message_id())), "?before=" <> message_text),
    #(Some(message.After(message_id())), "?after=" <> message_text),
  ]

  list.each(cursors, fn(row) {
    let #(cursor, expected) = row
    let call = message.list(channel_id(), cursor: cursor, limit: None)
    assert query_of(call) == expected
  })
}

pub fn a_cursor_and_a_limit_travel_together_test() {
  let call =
    message.list(
      channel_id(),
      cursor: Some(message.After(message_id())),
      limit: Some(100),
    )

  assert query_of(call) == "?after=" <> message_text <> "&limit=100"
}

/// The route takes its own two-variant kind, so the only values that reach
/// `type` are ones Discord accepts.
pub fn a_reaction_kind_renders_as_its_number_test() {
  let reactions = fn(type_) {
    message.reactions_id(
      channel_id(),
      message_id(),
      fire(),
      type_: type_,
      after: None,
      limit: None,
    )
  }

  assert query_of(reactions(Some(message.Normal))) == "?type=0"
  assert query_of(reactions(Some(message.Burst))) == "?type=1"
  assert query_of(reactions(None)) == ""
}

/// A reaction type off an event narrows before it can be sent. A kind added
/// after this build comes back as its number, which is a value to handle and
/// not one to put on a query string.
pub fn an_unknown_reaction_type_cannot_reach_the_query_test() {
  assert message.reaction_kind(message.NormalReaction) == Ok(message.Normal)
  assert message.reaction_kind(message.BurstReaction) == Ok(message.Burst)
  assert message.reaction_kind(message.UnknownReactionType(7))
    == Error(message.UnsendableReaction(wire_value: 7))
}

/// Zero is a value. A library that treats it as absence cannot express it.
pub fn a_zero_limit_is_sent_test() {
  let call = message.list(channel_id(), cursor: None, limit: Some(0))

  assert query_of(call) == "?limit=0"
}

/// The same one-cursor rule on the two id cursors: `before` and `after` page
/// in opposite directions, and neither type can hold both.
pub fn an_id_cursor_emits_exactly_one_parameter_test() {
  let bans = fn(cursor) { guild.bans(guild_id(), cursor: cursor, limit: None) }

  assert query_of(bans(None)) == ""
  assert query_of(bans(Some(guild.BansBefore(user_id()))))
    == "?before=" <> user_text
  assert query_of(bans(Some(guild.BansAfter(user_id()))))
    == "?after=" <> user_text

  let mine = fn(cursor) {
    guild.mine(cursor: cursor, limit: None, with_counts: False)
  }

  assert query_of(mine(Some(guild.GuildsBefore(guild_id()))))
    == "?before=" <> guild_text <> "&with_counts=false"
  assert query_of(mine(Some(guild.GuildsAfter(guild_id()))))
    == "?after=" <> guild_text <> "&with_counts=false"
}

/// Pins and archived threads page by instant, not by snowflake, so they take
/// a cursor of their own and a message id will not compile into one.
pub fn a_time_cursor_travels_as_a_timestamp_test() {
  let before = channel.at_time("2021-04-20T20:40:30.000Z")
  let call = message.pins(channel_id(), before: Some(before), limit: None)

  assert query_of(call) == "?before=2021-04-20T20%3A40%3A30.000Z"
}

/// Name and topic edits carry an undocumented limit of their own, and the
/// call asks which it is rather than trusting the caller to remember a second
/// combinator afterwards.
pub fn the_name_or_topic_bucket_splits_the_channel_patch_test() {
  let base = channel.edit_guild_channel()
  let renaming = channel.EditGuildChannel(..base, name: Some("general"))

  let plain = channel.edit(channel_id(), base)
  let split = channel.edit(channel_id(), renaming)

  assert route.sublimit(rest.route(plain)) == route.NoSublimit
  assert route.sublimit(rest.route(split)) == route.Named("name-or-topic")
  assert route.template(rest.route(split)) == route.template(rest.route(plain))

  // A thread edit at the same URL splits on name too.
  let thread = channel.EditThread(..channel.new_edit_thread(), name: Some("t"))
  let split_thread = channel.edit_thread(channel_id(), thread)
  assert route.sublimit(rest.route(split_thread))
    == route.Named("name-or-topic")
}

/// A standard emoji goes out as percent-encoded UTF-8, a custom one as
/// `name:id`, and a nameless one as `e:id`: Discord reads only the id.
pub fn reaction_emoji_encoding_test() {
  let emoji = id.from_string("123")
  let cases = [
    #(
      message.unicode_emoji("🏳️‍⚧️"),
      "%F0%9F%8F%B3%EF%B8%8F%E2%80%8D%E2%9A%A7%EF%B8%8F",
    ),
    #(message.custom_emoji(emoji, "rarity"), "rarity%3A123"),
    #(message.custom_emoji_by_id(emoji), "e%3A123"),
  ]

  list.each(cases, fn(row) {
    let #(reaction, expected) = row
    let call = message.react_id(channel_id(), message_id(), reaction)
    assert path_of(call) == reactions_path() <> "/" <> expected <> "/@me"
  })
}

/// An emoji that arrived on a reaction event goes back out as the same path
/// segment. A custom one deleted since has lost its name, and Discord reads
/// only the id, so `e` stands in rather than leaving a malformed `:123`.
pub fn a_wire_emoji_becomes_a_reaction_param_test() {
  let emoji_id = id.from_string("123")
  let cases = [
    #(emoji.unicode("🔥"), fire_encoded),
    #(emoji.unicode("🏳️‍⚧️"), "%F0%9F%8F%B3%EF%B8%8F%E2%80%8D%E2%9A%A7%EF%B8%8F"),
    #(emoji.custom(emoji_id, "rarity"), "rarity%3A123"),
    #(
      emoji.Emoji(kind: emoji.Custom(id: emoji_id, name: None), animated: False),
      "e%3A123",
    ),
  ]

  list.each(cases, fn(row) {
    let #(sent, expected) = row
    let call =
      message.react_id(channel_id(), message_id(), message.reaction_emoji(sent))
    assert path_of(call) == reactions_path() <> "/" <> expected <> "/@me"
  })
}

/// Reactions on one message share a bucket however the emoji is spelt.
/// Clearing them all has no emoji to collapse, so it keeps its own.
pub fn every_named_reaction_route_shares_one_template_test() {
  let named = [
    message.react_id(channel_id(), message_id(), fire()),
    message.unreact_id(channel_id(), message_id(), fire()),
    message.remove_reaction_id(channel_id(), message_id(), fire(), user_id()),
    message.clear_emoji_reactions_id(channel_id(), message_id(), fire()),
    message.clear_emoji_reactions_id(
      channel_id(),
      message_id(),
      message.custom_emoji(id.from_string(emoji_text), "shrug"),
    ),
  ]

  let templates = list.map(named, fn(call) { route.template(rest.route(call)) })
  assert set.size(set.from_list(templates)) == 1

  let all = message.clear_reactions_id(channel_id(), message_id())
  assert route.template(rest.route(all)) != reaction_template
}

/// `@me` is a literal, so editing your own member is a different bucket from
/// editing somebody else's.
pub fn at_me_is_not_an_id_test() {
  let mine = guild.edit_me(guild_id(), member.edit_current_member())
  let theirs =
    guild.edit_member(guild_id(), user_id(), member.edit_guild_member())

  assert route.template(rest.route(mine)) != route.template(rest.route(theirs))
}

/// Listing roles and moving them share a path, so the method is part of the
/// key or one inherits the other's budget.
pub fn the_method_separates_two_routes_on_one_path_test() {
  let listing = guild.roles(guild_id())
  let creating = guild.create_role(guild_id(), role.create_role())

  assert route.template(rest.route(listing))
    == route.template(rest.route(creating))
  assert route.key(rest.route(listing), now_ms: 0)
    != route.key(rest.route(creating), now_ms: 0)
}

/// Per-guild registrations are limited per guild, so the guild id is the major
/// even though the application id comes first in the path.
pub fn guild_commands_take_the_guild_major_test() {
  let global =
    application_command.get_global_commands(
      application_id(),
      with_localizations: False,
    )
  let in_guild =
    application_command.get_guild_commands(
      application_id(),
      guild_id(),
      with_localizations: False,
    )

  assert route.same_major(route.major(rest.route(global)), route.NoMajor)
  assert route.same_major(
    route.major(rest.route(in_guild)),
    route.GuildMajor(guild_text),
  )
}

/// Two guilds must not share a bucket, or one busy server stalls the rest.
pub fn two_guilds_are_two_buckets_test() {
  let first = guild.roles(guild_id())
  let second = guild.roles(id.from_string("81384788765712384"))

  assert route.template(rest.route(first)) == route.template(rest.route(second))
  assert route.key(rest.route(first), now_ms: 0)
    != route.key(rest.route(second), now_ms: 0)
}

/// A webhook token belongs in the major parameter, never the template, which
/// is the half of the route a log or a metric label is likely to carry.
pub fn tokens_stay_out_of_templates_test() {
  let followup = interaction.create_followup(responder(), payload())
  let callback = interaction.callback(responder(), payload())

  // The two decode different types, so they do not fit in one list.
  list.each([rest.route(followup), rest.route(callback)], fn(found) {
    assert string.contains(route.template(found), interaction_token) == False
  })

  assert string.contains(path_of(followup), interaction_token)
}

/// A follow-up route is the webhook route with the application id in the
/// webhook id's place.
pub fn a_followup_is_a_webhook_call_test() {
  let as_interaction = interaction.get_original_response(responder())
  let as_webhook =
    webhook.get_original_message(
      webhook.credential(id.from_string(application_text), interaction_token),
      thread: None,
    )

  assert route.key(rest.route(as_interaction), now_ms: 0)
    == route.key(rest.route(as_webhook), now_ms: 0)
  assert path_of(as_interaction) == path_of(as_webhook)
}

/// `wait` changes what comes back, so it is two functions and not a boolean.
pub fn waiting_on_a_webhook_is_a_query_parameter_test() {
  let fire_and_forget =
    webhook.execute(webhook_credential(), payload(), thread: None)
  let waiting =
    webhook.execute_and_wait(webhook_credential(), payload(), thread: None)

  assert query_of(fire_and_forget) == ""
  assert query_of(waiting) == "?wait=true"
  assert route.template(rest.route(fire_and_forget))
    == route.template(rest.route(waiting))
}

pub fn a_thread_id_targets_a_thread_test() {
  let call =
    webhook.execute_and_wait(
      webhook_credential(),
      payload(),
      thread: Some(thread_id()),
    )

  assert query_of(call) == "?wait=true&thread_id=" <> thread_text
}

fn authorization_of(call: rest.Call(a)) -> Result(String, Nil) {
  list.key_find(rest.request(config(), call).headers, "authorization")
}

/// The webhook and interaction routes carry their credential in the path, so
/// they send no `Authorization` header even out of a bot's `Config`. A 401
/// there is about that path credential and nothing else.
pub fn a_path_credential_replaces_the_bot_token_test() {
  let sent =
    webhook.execute(webhook_credential(), payload(), thread: None)
    |> authorization_of
  let answered = authorization_of(interaction.callback(responder(), payload()))
  let followed_up =
    authorization_of(interaction.create_followup(responder(), payload()))
  let ordinary = authorization_of(message.send(channel_id(), message.new()))

  assert sent == Error(Nil)
  assert answered == Error(Nil)
  assert followed_up == Error(Nil)
  assert ordinary == Ok("Bot MTk4NjIyNDgzNDcxOTI1MjQ4.s3cret")
}

pub fn a_callback_can_ask_for_its_response_test() {
  let quiet = interaction.callback(responder(), payload())
  let loud = interaction.callback_with_response(responder(), payload())

  assert query_of(quiet) == ""
  assert query_of(loud) == "?with_response=true"
  assert route.unbound(rest.route(loud))
}

/// The delete-message sublimit is read out of the snowflake, so this uses
/// Discord's own worked example.
pub fn a_message_knows_when_it_was_created_test() {
  let cases = [
    #("175928847299117063", 1_462_015_105_796),
    #(channel_text, 1_430_029_616_934),
    #(message_text, 1_493_740_342_133),
  ]

  list.each(cases, fn(row) {
    let #(text, expected) = row
    assert id.created_at_ms_or(
        id.from_string(text),
        default: id.discord_epoch_ms,
      )
      == expected
  })
}

/// Discord splits message deletion three ways by age and says so in no header,
/// so the route carries the age. Editing the same message does not.
pub fn deleting_a_message_is_bucketed_by_its_age_test() {
  let born = id.created_at_ms_or(message_id(), default: id.discord_epoch_ms)
  let deleting = rest.route(message.delete_id(channel_id(), message_id()))
  let editing =
    rest.route(message.edit_id(
      channel_id(),
      message_id(),
      message.new_edit(mentions.none()),
    ))

  let fresh = route.key(deleting, now_ms: born + 10_000)
  let normal = route.key(deleting, now_ms: born + 10_001)
  let ancient = route.key(deleting, now_ms: born + 1_209_600_000)

  assert set.size(set.from_list([fresh, normal, ancient])) == 3
  assert route.key(editing, now_ms: born)
    == route.key(editing, now_ms: born + 1_209_600_000)
}

/// A 204 route has nothing to decode, and an empty body is not a failure.
pub fn a_no_content_route_decodes_nothing_test() {
  let call = channel.typing(channel_id())
  assert rest.response(call, status: 204, headers: [], body: <<>>) == Ok(Nil)
}

/// A wrapped endpoint answers in the model.
pub fn a_json_route_decodes_into_its_model_test() {
  let call = message.get(channel_id(), message_id())

  let assert Ok(fetched) =
    rest.response(call, status: 200, headers: [], body: <<
      "{\"id\":\"7\",\"channel_id\":\"9\",\"author\":{\"id\":\"3\"},\"content\":\"pong\"}":utf8,
    >>)

  assert fetched.id == id.from_string("7")
  assert fetched.content == "pong"
  assert fetched.author.id == id.from_string("3")
}

/// An unmodelled endpoint is still `rest.get` and a decoder you wrote.
pub fn a_hand_rolled_call_keeps_its_own_decoder_test() {
  let call =
    rest.get(
      [seg.lit("guilds"), seg.guild(guild_id()), seg.lit("audit-logs")],
      rest.Decoded(decode.field("id", decode.string, decode.success)),
    )

  assert rest.response(call, status: 200, headers: [], body: <<
      "{\"id\":\"7\"}":utf8,
    >>)
    == Ok("7")
}

/// A hand-rolled call gets the same major parameter and goes through the
/// limiter the same way.
pub fn a_hand_rolled_call_goes_through_the_limiter_test() {
  let call =
    rest.get(
      [seg.lit("guilds"), seg.guild(guild_id()), seg.lit("audit-logs")],
      rest.Decoded(nothing()),
    )
    |> rest.query(
      list.flatten([
        query.opt("user_id", Some(user_id()), query.snowflake),
        query.opt("limit", Some(50), query.number),
      ]),
    )

  assert route.same_major(
    route.major(rest.route(call)),
    route.GuildMajor(guild_text),
  )
  assert path_of(call) == guild_path() <> "/audit-logs"
  assert query_of(call) == "?user_id=" <> user_text <> "&limit=50"

  let #(state, out) =
    limiter.step(
      limiter.new(limiter.defaults()),
      now_ms: 0,
      input: limiter.Submit(limiter.Ticket(1), rest.route(call)),
    )
  assert list.contains(out, limiter.Send(limiter.Ticket(1)))

  // It teaches the limiter too: traffic that goes around one breaks the
  // invalid-request budget for everything sharing the address.
  let #(state, out) =
    limiter.step(
      state,
      now_ms: 1,
      input: limiter.Settled(
        limiter.Ticket(1),
        headers.to_limiter_outcome(headers.outcome(
          200,
          [
            #("x-ratelimit-bucket", "abcd"),
            #("x-ratelimit-limit", "5"),
            #("x-ratelimit-remaining", "0"),
            #("x-ratelimit-reset-after", "5.0"),
          ],
          "",
        )),
      ),
    )
  assert list.contains(
    out,
    limiter.Note(limiter.BucketLearned(
      route_key: route.route_key(rest.route(call), now_ms: 1),
      bucket: "abcd",
    )),
  )

  let #(_, out) =
    limiter.step(
      state,
      now_ms: 2,
      input: limiter.Submit(limiter.Ticket(2), rest.route(call)),
    )
  assert list.contains(out, limiter.Send(limiter.Ticket(2))) == False
}

fn path_of(call: rest.Call(a)) -> String {
  string.replace(rest.request(config(), call).path, each: "/api/v10", with: "")
}

fn query_of(call: rest.Call(a)) -> String {
  case rest.request(config(), call).query {
    None -> ""
    Some(text) -> "?" <> text
  }
}
