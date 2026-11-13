//! Scale an image before a session stores it, with the limits of Claude Code. A provider scales a larger image down
//! anyway, so a large image costs upload time, memory, and disk for no gain. `fitImage` of the native module gives the
//! same scale to an image that the user attaches.

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType as PngFilter, PngEncoder};
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, ImageResult};
use rquickjs::{Ctx, Function, IntoJs, Object, Promise, TypedArray};

use crate::error::{ErrorClass, throw};
use crate::native::fs::Bytes;

/// The longest side of a stored image. The Anthropic API rejects a side above 2000 pixels when a request carries more
/// than 20 images.
const LONGEST_SIDE: u32 = 2000;

/// The most bytes of a stored image: 3.75 MiB, which is 5 MiB in base64, the image limit of the Anthropic API.
const MOST_BYTES: usize = 3_932_160;

/// The JPEG qualities to try, from the best, when the scaled image is still too large.
const JPEG_QUALITIES: [u8; 4] = [80, 60, 40, 20];

/// The width of the last try, which takes the lowest JPEG quality.
const LAST_WIDTH: u32 = 1000;

/// Add `fitImage(bytes, mimeType)`: a promise of the image as a session stores it, `{ bytes, mimeType }`.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "fitImage",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, bytes: TypedArray<'js, u8>, mime_type: String| -> rquickjs::Result<Promise<'js>> {
                let bytes = crate::bytes::copy(&bytes)?;
                let error_ctx = ctx.clone();
                Promise::wrap_future(&ctx, async move {
                    // A decode and an encode take long, so they run on a blocking thread of tokio.
                    match tokio::task::spawn_blocking(move || fit(bytes, mime_type)).await {
                        Ok((bytes, mime_type)) => Ok(Fitted {
                            bytes: Bytes(bytes),
                            mime_type,
                        }),
                        Err(error) => Err(throw(
                            &error_ctx,
                            ErrorClass::Error,
                            &format!("the image work failed: {error}"),
                        )),
                    }
                })
            },
        )?,
    )
}

/// What `fitImage` gives.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct Fitted {
    bytes: Bytes,
    mime_type: String,
}

/// The image `bytes` of the media type `mime_type` as a session stores it, and its media type. An image that fits stays
/// as it is. A larger one scales to fit [`LONGEST_SIDE`] and [`MOST_BYTES`]. Other media, and an image that does not
/// decode, stay as they are: the provider tells the model what is wrong with such a file.
pub(crate) fn fit(bytes: Vec<u8>, mime_type: String) -> (Vec<u8>, String) {
    let format = match mime_type.as_str() {
        "image/png" => ImageFormat::Png,
        "image/jpeg" => ImageFormat::Jpeg,
        "image/gif" => ImageFormat::Gif,
        "image/webp" => ImageFormat::WebP,
        _ => return (bytes, mime_type),
    };
    // The header gives the size, so an image that fits is never decoded.
    let Ok((width, height)) = ImageReader::with_format(Cursor::new(&bytes), format).into_dimensions() else {
        return (bytes, mime_type);
    };
    if width.max(height) <= LONGEST_SIDE && bytes.len() <= MOST_BYTES {
        return (bytes, mime_type);
    }
    match scale(&bytes, format) {
        Ok((scaled, scaled_type)) => (scaled, scaled_type.to_owned()),
        Err(_) => (bytes, mime_type),
    }
}

/// Decode `bytes` of `format`, and encode it to fit. A PNG, GIF, or WebP image first tries PNG. Then each image tries
/// JPEG at each of [`JPEG_QUALITIES`]. The last try is a JPEG at most [`LAST_WIDTH`] wide at the lowest quality.
fn scale(bytes: &[u8], format: ImageFormat) -> ImageResult<(Vec<u8>, &'static str)> {
    let mut decoder = ImageReader::with_format(Cursor::new(bytes), format).into_decoder()?;
    // The encoders write no EXIF, so the pixels take the orientation of the camera.
    let orientation = decoder.orientation()?;
    let mut image = DynamicImage::from_decoder(decoder)?;
    image.apply_orientation(orientation);
    // `thumbnail` also enlarges, so a small image keeps its size. It makes no float copy of the image, as `resize`
    // does, so a large screenshot takes less memory. Near the limit, a thin line can lose half its contrast.
    if image.width().max(image.height()) > LONGEST_SIDE {
        image = image.thumbnail(LONGEST_SIDE, LONGEST_SIDE);
    }

    if format != ImageFormat::Jpeg {
        // The default compression with adaptive filters makes a screenshot of text about half the size that the fast
        // compression of `write_to` makes, for about 50 ms.
        let mut png = Vec::new();
        image.write_with_encoder(PngEncoder::new_with_quality(
            &mut png,
            CompressionType::Default,
            PngFilter::Adaptive,
        ))?;
        if png.len() <= MOST_BYTES {
            return Ok((png, "image/png"));
        }
    }
    // JPEG has no alpha channel.
    let mut rgb = DynamicImage::ImageRgb8(image.into_rgb8());
    for quality in JPEG_QUALITIES {
        let jpeg = encode_jpeg(&rgb, quality)?;
        if jpeg.len() <= MOST_BYTES {
            return Ok((jpeg, "image/jpeg"));
        }
    }
    if rgb.width() > LAST_WIDTH {
        rgb = rgb.thumbnail(LAST_WIDTH, u32::MAX);
    }
    let [.., lowest] = JPEG_QUALITIES;
    Ok((encode_jpeg(&rgb, lowest)?, "image/jpeg"))
}

/// `image` as a JPEG of `quality`.
fn encode_jpeg(image: &DynamicImage, quality: u8) -> ImageResult<Vec<u8>> {
    let mut jpeg = Vec::new();
    image.write_with_encoder(JpegEncoder::new_with_quality(&mut jpeg, quality))?;
    Ok(jpeg)
}

#[cfg(test)]
mod tests {
    use image::{GenericImageView, ImageEncoder, Rgb, RgbImage, Rgba, RgbaImage};

    use super::*;

    fn encoded(image: &DynamicImage, format: ImageFormat) -> Vec<u8> {
        let mut bytes = Vec::new();
        image.write_to(Cursor::new(&mut bytes), format).unwrap();
        bytes
    }

    fn size(bytes: &[u8]) -> (u32, u32) {
        image::load_from_memory(bytes).unwrap().dimensions()
    }

    /// A noise image: no encoder compresses it much.
    fn noise(width: u32, height: u32) -> DynamicImage {
        let mut state = 0x2545_f491_u32;
        DynamicImage::ImageRgb8(RgbImage::from_fn(width, height, |_, _| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            let [r, g, b, _] = state.to_le_bytes();
            Rgb([r, g, b])
        }))
    }

    #[test]
    fn an_image_that_fits_keeps_its_bytes_and_its_type() {
        let png = encoded(&noise(2000, 40), ImageFormat::Png);

        let (bytes, mime_type) = fit(png.clone(), "image/png".to_owned());

        assert_eq!(bytes, png);
        assert_eq!(mime_type, "image/png");
    }

    #[test]
    fn a_wide_image_scales_to_2000_pixels_and_keeps_its_aspect_and_its_format() {
        let flat = DynamicImage::ImageRgba8(RgbaImage::from_pixel(4000, 1000, Rgba([10, 20, 30, 128])));

        let (png, png_type) = fit(encoded(&flat, ImageFormat::Png), "image/png".to_owned());
        let (jpeg, jpeg_type) = fit(
            encoded(&flat.to_rgb8().into(), ImageFormat::Jpeg),
            "image/jpeg".to_owned(),
        );

        assert_eq!((size(&png), png_type.as_str()), ((2000, 500), "image/png"));
        assert_eq!((size(&jpeg), jpeg_type.as_str()), ((2000, 500), "image/jpeg"));
    }

    #[test]
    fn a_jpeg_with_exif_orientation_is_rotated_before_it_scales() {
        // A little-endian TIFF header with one entry: Orientation (0x0112) = 6, which rotates 90 degrees clockwise.
        let exif = b"II*\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0\x06\0\0\0\0\0\0\0".to_vec();
        let flat = DynamicImage::ImageRgb8(RgbImage::from_pixel(4000, 1000, Rgb([10, 20, 30])));
        let mut jpeg = Vec::new();
        let mut encoder = JpegEncoder::new(&mut jpeg);
        encoder.set_exif_metadata(exif).unwrap();
        flat.write_with_encoder(encoder).unwrap();

        let (bytes, _) = fit(jpeg, "image/jpeg".to_owned());

        assert_eq!(size(&bytes), (500, 2000));
    }

    #[test]
    fn other_media_and_an_image_that_does_not_decode_stay_as_they_are() {
        for (bytes, mime_type) in [
            (b"%PDF-1.7".to_vec(), "application/pdf"),
            (b"\x89PNG\r\n\x1a\nbroken".to_vec(), "image/png"),
        ] {
            assert_eq!(fit(bytes.clone(), mime_type.to_owned()), (bytes, mime_type.to_owned()));
        }
    }
}
