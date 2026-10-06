//! Offscreen synthetic benchmark images and Apple Vision recognition.
//! No windows, Accessibility, capture, input, browsers, or models are used here.
use objc2::AnyThread;
use objc2_core_graphics::CGImage;
use objc2_foundation::{NSArray, NSDictionary, NSString};
use objc2_vision::{
    VNImageRequestHandler, VNRecognizeTextRequest, VNRequest, VNRequestTextRecognitionLevel,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, ffi::c_void, ptr};

#[derive(Debug, thiserror::Error)]
#[error("Offscreen benchmark image operation failed ({0})")]
pub struct ImageError(pub &'static str);
type Result<T> = std::result::Result<T, ImageError>;
fn require(valid: bool, code: &'static str) -> Result<()> {
    if valid { Ok(()) } else { Err(ImageError(code)) }
}
type Raw = *const c_void;
#[repr(C)]
#[derive(Clone, Copy)]
struct Point {
    x: f64,
    y: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Size {
    width: f64,
    height: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Rect {
    origin: Point,
    size: Size,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Transform {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    tx: f64,
    ty: f64,
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Raw);
    fn CFStringCreateWithBytes(
        allocator: Raw,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> Raw;
    fn CFDictionaryCreate(
        allocator: Raw,
        keys: *const Raw,
        values: *const Raw,
        count: isize,
        key_callbacks: Raw,
        value_callbacks: Raw,
    ) -> Raw;
    fn CFAttributedStringCreate(allocator: Raw, text: Raw, attributes: Raw) -> Raw;
    fn CFDataCreate(allocator: Raw, bytes: *const u8, length: isize) -> Raw;
    fn CFDataCreateMutable(allocator: Raw, capacity: isize) -> Raw;
    fn CFDataGetLength(data: Raw) -> isize;
    fn CFDataGetBytePtr(data: Raw) -> *const u8;
}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGColorSpaceCreateDeviceRGB() -> Raw;
    fn CGColorCreateGenericRGB(r: f64, g: f64, b: f64, a: f64) -> Raw;
    fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits: usize,
        row: usize,
        space: Raw,
        info: u32,
    ) -> Raw;
    fn CGBitmapContextCreateImage(context: Raw) -> Raw;
    fn CGPathCreateWithRoundedRect(rect: Rect, radius_x: f64, radius_y: f64, transform: Raw)
    -> Raw;
    fn CGContextAddPath(context: Raw, path: Raw);
    fn CGContextSetFillColorWithColor(context: Raw, color: Raw);
    fn CGContextFillPath(context: Raw);
    fn CGContextSetStrokeColorWithColor(context: Raw, color: Raw);
    fn CGContextSetLineWidth(context: Raw, width: f64);
    fn CGContextStrokePath(context: Raw);
    fn CGContextSetTextMatrix(context: Raw, transform: Transform);
    fn CGContextSetTextPosition(context: Raw, x: f64, y: f64);
    fn CGImageGetWidth(image: Raw) -> usize;
    fn CGImageGetHeight(image: Raw) -> usize;
}
#[link(name = "CoreText", kind = "framework")]
unsafe extern "C" {
    static kCTFontAttributeName: Raw;
    static kCTForegroundColorAttributeName: Raw;
    fn CTFontCreateWithName(name: Raw, size: f64, matrix: Raw) -> Raw;
    fn CTLineCreateWithAttributedString(value: Raw) -> Raw;
    fn CTLineGetBoundsWithOptions(line: Raw, options: usize) -> Rect;
    fn CTLineDraw(line: Raw, context: Raw);
}
#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageDestinationCreateWithData(data: Raw, kind: Raw, count: usize, options: Raw) -> Raw;
    fn CGImageDestinationAddImage(destination: Raw, image: Raw, properties: Raw);
    fn CGImageDestinationFinalize(destination: Raw) -> u8;
    fn CGImageSourceCreateWithData(data: Raw, options: Raw) -> Raw;
    fn CGImageSourceGetCount(source: Raw) -> usize;
    fn CGImageSourceGetType(source: Raw) -> Raw;
    fn CGImageSourceCreateImageAtIndex(source: Raw, index: usize, options: Raw) -> Raw;
    fn CFEqual(a: Raw, b: Raw) -> u8;
}
/// All CF Create/Copy references remain in this module and are released once.
struct Owned(Raw);
impl Owned {
    fn new(value: Raw) -> Result<Self> {
        if value.is_null() {
            Err(ImageError("native_allocation_failed"))
        } else {
            Ok(Self(value))
        }
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: self owns a nonnull Create-rule CF reference.
        unsafe { CFRelease(self.0) }
    }
}
fn string(text: &str) -> Result<Owned> {
    // SAFETY: bounded UTF8 bytes live through copying CF initializer.
    Owned::new(unsafe {
        CFStringCreateWithBytes(
            ptr::null(),
            text.as_ptr(),
            text.len() as isize,
            0x08000100,
            0,
        )
    })
}
fn color(text: &str) -> Result<Owned> {
    require(
        text.len() == 7 && text.starts_with('#'),
        "invalid_fixture_color",
    )?;
    let n = u32::from_str_radix(&text[1..], 16).map_err(|_| ImageError("invalid_fixture_color"))?;
    // SAFETY: four finite unit channels, Create-rule ownership.
    Owned::new(unsafe {
        CGColorCreateGenericRGB(
            ((n >> 16) & 255) as f64 / 255.0,
            ((n >> 8) & 255) as f64 / 255.0,
            (n & 255) as f64 / 255.0,
            1.0,
        )
    })
}
fn finite(value: &Value, key: &str) -> Result<f64> {
    value[key]
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or(ImageError("invalid_fixture_number"))
}
fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .ok_or(ImageError("invalid_fixture_string"))
}
fn encode(context: &Owned) -> Result<Vec<u8>> {
    // SAFETY: valid owned bitmap context; image, data and destination live through finalization.
    unsafe {
        let image = Owned::new(CGBitmapContextCreateImage(context.0))?;
        let data = Owned::new(CFDataCreateMutable(ptr::null(), 0))?;
        let kind = string("public.png")?;
        let destination = Owned::new(CGImageDestinationCreateWithData(
            data.0,
            kind.0,
            1,
            ptr::null(),
        ))?;
        CGImageDestinationAddImage(destination.0, image.0, ptr::null());
        require(
            CGImageDestinationFinalize(destination.0) != 0,
            "png_encoding_failed",
        )?;
        let length = CFDataGetLength(data.0);
        require(length > 0 && length <= 32 * 1024 * 1024, "png_byte_bound")?;
        let bytes = CFDataGetBytePtr(data.0);
        require(!bytes.is_null(), "png_encoding_failed")?;
        Ok(std::slice::from_raw_parts(bytes, length as usize).to_vec())
    }
}
fn render_one(observation: &Value) -> Result<Vec<u8>> {
    let primitives = observation["primitives"]
        .as_array()
        .ok_or(ImageError("invalid_fixture_primitives"))?;
    require(
        !primitives.is_empty() && primitives.len() <= 512,
        "fixture_primitive_bound",
    )?;
    // SAFETY: fixed dimensions/bits/color space; context allocates its own private buffer.
    let space = Owned::new(unsafe { CGColorSpaceCreateDeviceRGB() })?;
    // SAFETY: the fixed bitmap dimensions/bits and owned RGB space are valid; it allocates its buffer.
    let context =
        Owned::new(unsafe { CGBitmapContextCreate(ptr::null_mut(), 1000, 650, 8, 0, space.0, 1) })?;
    for primitive in primitives {
        let x = finite(primitive, "x")?;
        let y = finite(primitive, "y")?;
        require(
            (0.0..=1000.0).contains(&x) && (0.0..=650.0).contains(&y),
            "fixture_coordinates_outside_canvas",
        )?;
        let paint = color(text(primitive, "fill")?)?;
        match text(primitive, "kind")? {
            "rect" => {
                let width = finite(primitive, "width")?;
                let height = finite(primitive, "height")?;
                let radius = if primitive["radius"].is_null() {
                    0.0
                } else {
                    finite(primitive, "radius")?
                };
                require(
                    width > 0.0
                        && height > 0.0
                        && x + width <= 1000.0
                        && y + height <= 650.0
                        && radius >= 0.0
                        && radius <= width.min(height) / 2.0,
                    "invalid_fixture_rectangle",
                )?;
                let rect = Rect {
                    origin: Point {
                        x,
                        y: 650.0 - y - height,
                    },
                    size: Size { width, height },
                };
                // SAFETY: bounded rectangle, owned context/path/colors; drawing is synchronous.
                unsafe {
                    let path = Owned::new(CGPathCreateWithRoundedRect(
                        rect,
                        radius,
                        radius,
                        ptr::null(),
                    ))?;
                    CGContextAddPath(context.0, path.0);
                    CGContextSetFillColorWithColor(context.0, paint.0);
                    CGContextFillPath(context.0);
                    if let Some(stroke) = primitive["stroke"].as_str() {
                        let stroke = color(stroke)?;
                        CGContextAddPath(context.0, path.0);
                        CGContextSetStrokeColorWithColor(context.0, stroke.0);
                        CGContextSetLineWidth(context.0, 1.0);
                        CGContextStrokePath(context.0);
                    }
                }
            }
            "text" => {
                let value = text(primitive, "text")?;
                let size = finite(primitive, "size")?;
                require(
                    !value.is_empty()
                        && value.len() <= 8192
                        && (1.0..=128.0).contains(&size)
                        && y - size >= 0.0,
                    "invalid_fixture_text",
                )?;
                let font_name = string(if primitive["weight"].as_u64().unwrap_or(400) >= 600 {
                    "Arial-BoldMT"
                } else {
                    "ArialMT"
                })?;
                let content = string(value)?;
                // SAFETY: immutable typed CF references remain alive through line construction/drawing.
                unsafe {
                    let font = Owned::new(CTFontCreateWithName(font_name.0, size, ptr::null()))?;
                    let keys = [kCTFontAttributeName, kCTForegroundColorAttributeName];
                    let values = [font.0, paint.0];
                    let attributes = Owned::new(CFDictionaryCreate(
                        ptr::null(),
                        keys.as_ptr(),
                        values.as_ptr(),
                        2,
                        ptr::null(),
                        ptr::null(),
                    ))?;
                    let attributed = Owned::new(CFAttributedStringCreate(
                        ptr::null(),
                        content.0,
                        attributes.0,
                    ))?;
                    let line = Owned::new(CTLineCreateWithAttributedString(attributed.0))?;
                    let bounds = CTLineGetBoundsWithOptions(line.0, 1 << 3);
                    require(
                        bounds.size.width.is_finite() && x + bounds.size.width <= 1000.0,
                        "fixture_text_outside_canvas",
                    )?;
                    CGContextSetTextMatrix(
                        context.0,
                        Transform {
                            a: 1.0,
                            b: 0.0,
                            c: 0.0,
                            d: 1.0,
                            tx: 0.0,
                            ty: 0.0,
                        },
                    );
                    CGContextSetTextPosition(context.0, x, 650.0 - y);
                    CTLineDraw(line.0, context.0);
                }
            }
            _ => return Err(ImageError("unknown_fixture_primitive")),
        }
    }
    encode(&context)
}
#[derive(Debug)]
pub struct RenderedFixture {
    pub name: String,
    pub png: Vec<u8>,
}
/// Original fixed 1000x650 renderer, including optional prior observations.
pub fn render(fixtures: &Value) -> Result<Vec<RenderedFixture>> {
    let list = fixtures
        .as_array()
        .ok_or(ImageError("invalid_fixture_list"))?;
    require(!list.is_empty() && list.len() <= 64, "fixture_count_bound")?;
    let mut names = HashSet::new();
    let mut result = vec![];
    for fixture in list {
        let id = text(fixture, "id")?;
        require(
            !id.is_empty()
                && id.len() <= 128
                && id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
            "invalid_fixture_id",
        )?;
        for (name, observation) in std::iter::once((id.to_string(), fixture)).chain(
            fixture
                .get("priorObservation")
                .map(|prior| (format!("{id}-prior"), prior)),
        ) {
            require(names.insert(name.clone()), "duplicate_fixture_id")?;
            result.push(RenderedFixture {
                name,
                png: render_one(observation)?,
            });
        }
    }
    Ok(result)
}
/// Bounded original PNG only. Call in an owned process with an external deadline:
/// Vision may ignore cooperative cancellation during cold model compilation.
pub fn recognize_png(bytes: &[u8], cpu_only: bool) -> Result<Value> {
    require(
        bytes.len() >= 24
            && bytes.len() <= 32 * 1024 * 1024
            && bytes[..8] == [137, 80, 78, 71, 13, 10, 26, 10]
            && bytes[12..16] == *b"IHDR",
        "invalid_bounded_png",
    )?;
    let width = u32::from_be_bytes(bytes[16..20].try_into().unwrap()) as usize;
    let height = u32::from_be_bytes(bytes[20..24].try_into().unwrap()) as usize;
    require(
        width > 0 && height > 0 && width <= 8_000_000 / height,
        "png_pixel_bound",
    )?;
    objc2::rc::autoreleasepool(|_| {
        // SAFETY: bounded immutable data; native decoder validates one PNG and exact dimensions.
        unsafe {
            let data = Owned::new(CFDataCreate(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len() as isize,
            ))?;
            let source = Owned::new(CGImageSourceCreateWithData(data.0, ptr::null()))?;
            let kind = string("public.png")?;
            require(
                CGImageSourceGetCount(source.0) == 1
                    && !CGImageSourceGetType(source.0).is_null()
                    && CFEqual(CGImageSourceGetType(source.0), kind.0) != 0,
                "expected_one_png",
            )?;
            let image = Owned::new(CGImageSourceCreateImageAtIndex(source.0, 0, ptr::null()))?;
            require(
                CGImageGetWidth(image.0) == width && CGImageGetHeight(image.0) == height,
                "png_dimensions_mismatch",
            )?;
            let request = VNRecognizeTextRequest::init(VNRecognizeTextRequest::alloc());
            request.setRecognitionLevel(VNRequestTextRecognitionLevel::Accurate);
            let language = NSString::from_str("en-US");
            request.setRecognitionLanguages(&NSArray::from_slice(&[&*language]));
            request.setUsesLanguageCorrection(false);
            request.setMinimumTextHeight(0.0);
            #[allow(deprecated)]
            if cpu_only {
                request.setUsesCPUOnly(true);
            }
            let handler = VNImageRequestHandler::initWithCGImage_options(
                VNImageRequestHandler::alloc(),
                &*image.0.cast::<CGImage>(),
                &NSDictionary::new(),
            );
            let requests = NSArray::from_slice(&[&*request as &VNRequest]);
            let started = std::time::Instant::now();
            handler
                .performRequests_error(&requests)
                .map_err(|_| ImageError("vision_recognition_failed_redacted"))?;
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            let observations = request.results();
            let detected = observations.as_ref().map_or(0, |values| values.len());
            require(detected <= 100_000, "ocr_result_count_bound")?;
            let mut records = vec![];
            if let Some(observations) = observations {
                for observation in observations.iter().take(128) {
                    let candidates = observation.topCandidates(1);
                    let Some(candidate) = candidates.iter().next() else {
                        continue;
                    };
                    let text = candidate.string().to_string();
                    let confidence = candidate.confidence();
                    let b = observation.boundingBox();
                    let box_values = [
                        b.origin.x,
                        1.0 - b.origin.y - b.size.height,
                        b.size.width,
                        b.size.height,
                    ];
                    if text.is_empty()
                        || text.len() > 512
                        || !(0.0..=1.0).contains(&confidence)
                        || !box_values
                            .iter()
                            .all(|n| n.is_finite() && (0.0..=1.0).contains(n))
                        || box_values[2] <= 0.0
                        || box_values[3] <= 0.0
                        || box_values[0] + box_values[2] > 1.000001
                        || box_values[1] + box_values[3] > 1.000001
                    {
                        continue;
                    }
                    records.push(json!({"text":text,"confidence":confidence,"box":box_values}));
                }
            }
            let result = json!({"schema_version":1,"recognizer":"apple_vision","recognition_level":"accurate","language":"en-US","uses_language_correction":false,"compute_policy":if cpu_only{"cpu_only"}else{"automatic"},"recognition_revision":request.revision(),"image_sha256":hex::encode(Sha256::digest(bytes)),"width":width,"height":height,"detected_count":detected,"omitted_count":detected-records.len(),"records":records,"elapsed_ms":elapsed});
            require(
                serde_json::to_vec(&result)
                    .map_err(|_| ImageError("ocr_encoding_failed"))?
                    .len()
                    <= 128 * 1024,
                "ocr_output_bound",
            )?;
            Ok(result)
        }
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offscreen_png_and_invalid_primitives() {
        let fixture = json!([{"id":"synthetic","primitives":[{"kind":"rect","x":0,"y":0,"width":1000,"height":650,"fill":"#ffffff"},{"kind":"text","x":10,"y":40,"text":"Synthetic only","size":22,"fill":"#172033"}]}]);
        let rows = render(&fixture).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].png[..8], [137, 80, 78, 71, 13, 10, 26, 10]);
        assert_eq!(
            u32::from_be_bytes(rows[0].png[16..20].try_into().unwrap()),
            1000
        );
        let mut bad = fixture.clone();
        bad[0]["primitives"][1]["x"] = json!(999);
        assert!(render(&bad).is_err());
        let duplicate = json!([fixture[0], fixture[0]]);
        assert!(render(&duplicate).is_err());
    }
    #[test]
    fn invalid_or_oversized_image_is_rejected_before_vision() {
        assert!(recognize_png(b"not an image", true).is_err());
        let mut bytes = vec![0u8; 24];
        bytes[..8].copy_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);
        bytes[12..16].copy_from_slice(b"IHDR");
        bytes[16..20].copy_from_slice(&100_000u32.to_be_bytes());
        bytes[20..24].copy_from_slice(&100_000u32.to_be_bytes());
        assert!(recognize_png(&bytes, true).is_err());
    }
}
