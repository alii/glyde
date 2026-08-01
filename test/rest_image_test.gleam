import glyde/rest/image

const png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

const jpeg_header = <<0xFF, 0xD8, 0xFF>>

const gif87a_header = <<0x47, 0x49, 0x46, 0x38, 0x37, 0x61>>

const gif89a_header = <<0x47, 0x49, 0x46, 0x38, 0x39, 0x61>>

fn uri(data: BitArray) -> String {
  let assert Ok(value) = image.from_bytes(data)
  image.to_string(value)
}

/// The mime is read off the bytes, so it cannot disagree with what is sent.
pub fn the_signature_names_the_mime_test() {
  assert uri(png_header) == "data:image/png;base64,iVBORw0KGgo="
  assert uri(jpeg_header) == "data:image/jpeg;base64,/9j/"
  assert uri(gif87a_header) == "data:image/gif;base64,R0lGODdh"
  assert uri(gif89a_header) == "data:image/gif;base64,R0lGODlh"
}

/// A data URI is standard base64, padded, not the URL-safe unpadded form.
pub fn the_bytes_after_the_signature_ride_along_test() {
  assert uri(<<png_header:bits, 1, 2, 3>>)
    == "data:image/png;base64,iVBORw0KGgoBAgM="
}

pub fn empty_bytes_are_not_an_image_test() {
  assert image.from_bytes(<<>>) == Error(image.ImageEmpty)
}

/// Discord answers 400 to anything but JPG, PNG and GIF, so the request is
/// never built. A WEBP header and a truncated PNG signature are both refused.
pub fn a_format_discord_does_not_take_is_refused_test() {
  let webp = <<0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50>>

  assert image.from_bytes(webp) == Error(image.UnknownFormat)
  assert image.from_bytes(<<0x89, 0x50, 0x4E>>) == Error(image.UnknownFormat)
  assert image.from_bytes(<<0xFF, 0xD8>>) == Error(image.UnknownFormat)
  assert image.from_bytes(<<"GIF88a":utf8>>) == Error(image.UnknownFormat)
}
