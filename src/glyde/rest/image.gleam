//// Images going up on an avatar, banner or icon field.
////
//// Discord returns a hash on those fields and takes a base64 data URI, so a
//// decoded `avatar` is not something you can send back. This is a separate
//// type built from bytes, which is what keeps the two apart.
////
//// Discord accepts JPG, PNG and GIF.

import gleam/bit_array
import gleam/json.{type Json}

/// `data:<mime>;base64,<bytes>`, the only form the image fields take.
pub opaque type ImageData {
  ImageData(uri: String)
}

/// Why bytes are not an image Discord takes.
pub type UnsupportedImage {
  ImageEmpty
  /// The bytes start with none of the three signatures.
  UnknownFormat
}

/// The mime label comes off the bytes, so a caller cannot promise a PNG and
/// send something else. Discord answers 400 to anything but JPG, PNG and GIF,
/// which is what the three signatures below cover.
pub fn from_bytes(data: BitArray) -> Result(ImageData, UnsupportedImage) {
  case data {
    <<>> -> Error(ImageEmpty)

    // RFC 2083 section 3.1: the eight-byte PNG signature.
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _:bytes>> ->
      Ok(data_uri("image/png", data))

    // JFIF and Exif both open with SOI and the next marker's 0xFF.
    <<0xFF, 0xD8, 0xFF, _:bytes>> -> Ok(data_uri("image/jpeg", data))

    // "GIF87a" and "GIF89a", the only two versions there are.
    <<0x47, 0x49, 0x46, 0x38, 0x37, 0x61, _:bytes>>
    | <<0x47, 0x49, 0x46, 0x38, 0x39, 0x61, _:bytes>> ->
      Ok(data_uri("image/gif", data))

    _ -> Error(UnknownFormat)
  }
}

/// The URI as it goes on the wire.
pub fn to_string(image: ImageData) -> String {
  image.uri
}

pub fn to_json(image: ImageData) -> Json {
  json.string(image.uri)
}

fn data_uri(mime: String, data: BitArray) -> ImageData {
  // Padded: a data URI is standard base64, not the URL-safe unpadded form.
  ImageData(
    "data:" <> mime <> ";base64," <> bit_array.base64_encode(data, True),
  )
}
