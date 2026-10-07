//! Offline image preparation. The resampler follows Pillow's RGB bicubic,
//! including downsample antialiasing and per-pass 22-bit coefficient rounding.
use super::GroundingError;
use image::RgbImage;
use serde_json::Value;
pub(super) fn png(data: &[u8]) -> Result<RgbImage, GroundingError> {
    if data.len() < 33
        || data.len() > 16 * 1024 * 1024
        || &data[..8] != b"\x89PNG\r\n\x1a\n"
        || &data[12..16] != b"IHDR"
    {
        return Err(GroundingError::Image);
    }
    let w = u32::from_be_bytes(data[16..20].try_into().map_err(|_| GroundingError::Image)?);
    let h = u32::from_be_bytes(data[20..24].try_into().map_err(|_| GroundingError::Image)?);
    if w == 0 || h == 0 || w > 8192 || h > 8192 || u64::from(w) * u64::from(h) > 16_777_216 {
        return Err(GroundingError::Image);
    }
    // APNG is not a single observation. Reject animation chunks before decoding.
    let mut offset = 8;
    let mut ended = false;
    while offset < data.len() {
        if offset + 12 > data.len() {
            return Err(GroundingError::Image);
        }
        let n = u32::from_be_bytes(
            data[offset..offset + 4]
                .try_into()
                .map_err(|_| GroundingError::Image)?,
        ) as usize;
        let end = offset
            .checked_add(n)
            .and_then(|n| n.checked_add(12))
            .filter(|n| *n <= data.len())
            .ok_or(GroundingError::Image)?;
        let kind = &data[offset + 4..offset + 8];
        if matches!(kind, b"acTL" | b"fcTL" | b"fdAT") {
            return Err(GroundingError::Image);
        }
        if kind == b"IEND" {
            if n != 0 || end != data.len() {
                return Err(GroundingError::Image);
            }
            ended = true;
        }
        offset = end;
    }
    if !ended {
        return Err(GroundingError::Image);
    }
    let decoded = image::load_from_memory_with_format(data, image::ImageFormat::Png)
        .map_err(|_| GroundingError::Image)?;
    if decoded.width() != w || decoded.height() != h {
        return Err(GroundingError::Image);
    }
    Ok(decoded.to_rgb8())
}
fn cubic(x: f64) -> f64 {
    let x = x.abs();
    if x < 1.0 {
        ((1.5 * x - 2.5) * x) * x + 1.0
    } else if x < 2.0 {
        (((-0.5 * x + 2.5) * x - 4.0) * x) + 2.0
    } else {
        0.0
    }
}
fn coefficients(input: usize, output: usize) -> Vec<(usize, Vec<i32>)> {
    let scale = input as f64 / output as f64;
    let filter_scale = scale.max(1.0);
    let support = 2.0 * filter_scale;
    (0..output)
        .map(|i| {
            let center = (i as f64 + 0.5) * scale;
            let start = ((center - support + 0.5) as isize).max(0) as usize;
            let end = ((center + support + 0.5) as usize).min(input);
            let mut coeff: Vec<f64> = (start..end)
                .map(|j| cubic((j as f64 - center + 0.5) / filter_scale))
                .collect();
            let sum: f64 = coeff.iter().sum();
            if sum != 0.0 {
                for c in &mut coeff {
                    *c /= sum;
                }
            }
            let coefficients = coeff
                .into_iter()
                .map(|c| {
                    if c < 0.0 {
                        (-0.5 + c * 4_194_304.0) as i32
                    } else {
                        (0.5 + c * 4_194_304.0) as i32
                    }
                })
                .collect();
            (start, coefficients)
        })
        .collect()
}
pub(super) fn bicubic(rgb: &RgbImage, width: u32, height: u32) -> RgbImage {
    if (rgb.width(), rgb.height()) == (width, height) {
        return rgb.clone();
    }
    let horizontal = coefficients(rgb.width() as usize, width as usize);
    let vertical = coefficients(rgb.height() as usize, height as usize);
    let mut middle = RgbImage::new(width, rgb.height());
    for y in 0..rgb.height() {
        for (x, (start, c)) in horizontal.iter().enumerate() {
            let mut sum = [2_097_152_i64; 3];
            for (i, k) in c.iter().enumerate() {
                let px = rgb.get_pixel((start + i) as u32, y);
                for channel in 0..3 {
                    sum[channel] += i64::from(px[channel]) * i64::from(*k);
                }
            }
            middle.put_pixel(
                x as u32,
                y,
                image::Rgb(sum.map(|v| (v >> 22).clamp(0, 255) as u8)),
            );
        }
    }
    let mut result = RgbImage::new(width, height);
    for (y, (start, c)) in vertical.iter().enumerate() {
        for x in 0..width {
            let mut sum = [2_097_152_i64; 3];
            for (i, k) in c.iter().enumerate() {
                let px = middle.get_pixel(x, (start + i) as u32);
                for channel in 0..3 {
                    sum[channel] += i64::from(px[channel]) * i64::from(*k);
                }
            }
            result.put_pixel(
                x,
                y as u32,
                image::Rgb(sum.map(|v| (v >> 22).clamp(0, 255) as u8)),
            );
        }
    }
    result
}
pub(super) fn florence_pixels(rgb: &RgbImage, cfg: &Value) -> Result<Vec<f32>, GroundingError> {
    let dimension = |key: &str| {
        cfg["size"][key]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| (1..=2048).contains(n))
            .ok_or(GroundingError::Processor)
    };
    let (width, height) = (dimension("width")?, dimension("height")?);
    if cfg["do_center_crop"] == true
        || cfg["do_resize"] != true
        || cfg["resample"] != 3
        || cfg["do_rescale"] != true
        || cfg["do_normalize"] != true
    {
        return Err(GroundingError::Processor);
    }
    let values = |key: &str| -> Result<[f32; 3], GroundingError> {
        let list = cfg[key]
            .as_array()
            .filter(|a| a.len() == 3)
            .ok_or(GroundingError::Processor)?;
        let mut out = [0.0; 3];
        for i in 0..3 {
            out[i] = list[i]
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or(GroundingError::Processor)? as f32;
        }
        Ok(out)
    };
    let mean = values("image_mean")?;
    let std = values("image_std")?;
    if std.iter().any(|n| *n <= 0.0) {
        return Err(GroundingError::Processor);
    }
    let rescale = cfg
        .get("rescale_factor")
        .and_then(Value::as_f64)
        .unwrap_or(1.0 / 255.0);
    if !rescale.is_finite() || rescale <= 0.0 {
        return Err(GroundingError::Processor);
    }
    let resized = bicubic(rgb, width, height);
    let plane = width as usize * height as usize;
    let mut result = vec![0.0; plane * 3];
    for (index, pixel) in resized.pixels().enumerate() {
        for channel in 0..3 {
            result[channel * plane + index] =
                ((f64::from(pixel[channel]) * rescale) as f32 - mean[channel]) / std[channel];
        }
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn png_observations_are_single_frame_and_dimension_bounded() {
        let image = RgbImage::from_pixel(2, 2, image::Rgb([50, 100, 200]));
        let mut data = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image.clone())
            .write_to(&mut data, image::ImageFormat::Png)
            .unwrap();
        let data = data.into_inner();
        assert_eq!(png(&data).unwrap(), image);
        let mut animation = data[..33].to_vec();
        animation.extend_from_slice(&[0, 0, 0, 0, b'a', b'c', b'T', b'L', 0, 0, 0, 0]);
        animation.extend_from_slice(&data[33..]);
        assert!(png(&animation).is_err());
        let mut excessive = data.clone();
        excessive[16..20].copy_from_slice(&8193_u32.to_be_bytes());
        assert!(png(&excessive).is_err());
        let mut trailing = data;
        trailing.push(0);
        assert!(png(&trailing).is_err());
    }
    #[test]
    fn bicubic_rgb_rounding_is_bounded_and_matches_pillow_fixture() {
        let mut image = RgbImage::new(2, 2);
        for (p, v) in
            image
                .pixels_mut()
                .zip([[0, 10, 20], [255, 128, 70], [10, 200, 30], [99, 40, 250]])
        {
            *p = image::Rgb(v);
        }
        assert_eq!(bicubic(&image, 1, 1).as_raw(), &vec![92, 95, 93]);
        let out = bicubic(&image, 3, 3);
        assert_eq!(out.get_pixel(1, 1), &image::Rgb([92, 95, 93]));
        assert_eq!(
            out.as_raw(),
            &vec![
                0, 0, 17, 133, 66, 39, 255, 143, 61, 2, 107, 17, 92, 95, 93, 180, 83, 164, 4, 225,
                16, 50, 123, 146, 95, 22, 255
            ]
        );
        assert_eq!(bicubic(&image, 2, 2), image);
    }
}
