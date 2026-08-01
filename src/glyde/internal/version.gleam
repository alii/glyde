//// `glyde.api_version` is the name to use. The number sits in a module of its
//// own because both halves of the library need it and `glyde/gateway` is a
//// pure state machine, so it cannot read the number out of `glyde/rest`.
////
//// Importing nothing is the point: this is the one module the gateway core
//// may depend on without learning what a wire format is.

/// The Discord API version glyde speaks, gateway and REST.
pub const number: Int = 10
