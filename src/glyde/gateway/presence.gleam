//// What the bot looks like in a member list: the dot next to its name and
//// the line under it.
////
//// Its own module because two frames carry the same object: op 3 sends one on
//// its own, and IDENTIFY carries the one to connect with. `gateway/command`
//// and `gateway/frame` both need it, and `frame` cannot import `command`.

import gleam/json.{type Json}
import gleam/option.{type Option, None}
import glyde/field.{Absent, Present}
import glyde/wire

pub type Presence {
  Presence(status: Status, activities: List(Activity), afk: Bool)
}

/// The dot next to the bot's name.
pub type Status {
  Online
  /// `since` is the unix milliseconds the bot went idle. It hangs off this
  /// variant because Discord's `since` is null for every other status, so
  /// there is no second place it could come from.
  Idle(since: Option(Int))
  DoNotDisturb
  Invisible
  /// For a bot this looks the same to everyone else as `Invisible`.
  Offline
}

/// The line under the bot's name. A bot may set only name, type, URL and state.
pub type Activity {
  /// "Playing {name}".
  Playing(name: String)
  /// "Streaming {name}". Discord checks the URL and only twitch.tv and
  /// youtube.com links work.
  Streaming(name: String, url: String)
  /// "Listening to {name}".
  Listening(name: String)
  /// "Watching {name}".
  Watching(name: String)
  /// "Competing in {name}".
  Competing(name: String)
  /// Just the text, with no verb in front of it.
  CustomStatus(text: String)
}

/// A presence that is nothing but a status.
pub fn new(status: Status) -> Presence {
  Presence(status:, activities: [], afk: False)
}

/// The object op 3 carries. IDENTIFY's `presence` field takes the same one.
pub fn to_json(presence: Presence) -> Json {
  json.object([
    // Always on the wire: a null here means the bot is not idle.
    #("since", json.nullable(idle_since(presence.status), json.int)),
    #("activities", json.array(presence.activities, activity_to_json)),
    #("status", json.string(status_to_string(presence.status))),
    #("afk", json.bool(presence.afk)),
  ])
}

fn idle_since(status: Status) -> Option(Int) {
  case status {
    Idle(since:) -> since
    Online | DoNotDisturb | Invisible | Offline -> None
  }
}

fn activity_to_json(activity: Activity) -> Json {
  let #(kind, name, url, state) = case activity {
    Playing(name:) -> #(0, name, Absent, Absent)
    Streaming(name:, url:) -> #(1, name, Present(url), Absent)
    Listening(name:) -> #(2, name, Absent, Absent)
    Watching(name:) -> #(3, name, Absent, Absent)
    Competing(name:) -> #(5, name, Absent, Absent)
    // Type 4 needs a name on the wire and never shows it; the visible text is
    // `state`. "Custom Status" is what Discord's own client sends.
    CustomStatus(text:) -> #(4, "Custom Status", Absent, Present(text))
  }
  wire.object([
    #("name", Present(json.string(name))),
    #("type", Present(json.int(kind))),
    // Omitted, not null: Discord rejects a null `url` on the other types.
    #("url", wire.put(url, json.string)),
    #("state", wire.put(state, json.string)),
  ])
}

fn status_to_string(status: Status) -> String {
  case status {
    Online -> "online"
    Idle(_) -> "idle"
    DoNotDisturb -> "dnd"
    Invisible -> "invisible"
    Offline -> "offline"
  }
}
