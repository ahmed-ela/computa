use crate::{AutomationError, CapturedImage, Point, Rect, Result};
use uuid::Uuid;
#[derive(Clone, Debug)]
pub struct ScreenshotCoordinateMapper {
    pub capture_id: Uuid,
    pub captured_at: f64,
    pub frame: Rect,
    pub image_width: usize,
    pub image_height: usize,
}
impl ScreenshotCoordinateMapper {
    pub fn new(image: &CapturedImage) -> Result<Self> {
        image.frame.validate()?;
        if image.width == 0 || image.height == 0 || !image.captured_at.is_finite() {
            return Err(AutomationError::Invalid("capture dimensions/time".into()));
        }
        Ok(Self {
            capture_id: image.id,
            captured_at: image.captured_at,
            frame: image.frame,
            image_width: image.width,
            image_height: image.height,
        })
    }
    pub fn screen_point(
        &self,
        capture_id: Uuid,
        x: f64,
        y: f64,
        now: f64,
        maximum_age: f64,
    ) -> Result<Point> {
        if capture_id != self.capture_id
            || !now.is_finite()
            || !maximum_age.is_finite()
            || maximum_age <= 0.
            || now - self.captured_at < 0.
            || now - self.captured_at > maximum_age
        {
            return Err(AutomationError::StaleObservation);
        }
        if !x.is_finite()
            || !y.is_finite()
            || x < 0.
            || y < 0.
            || x >= self.image_width as f64
            || y >= self.image_height as f64
        {
            return Err(AutomationError::Invalid("point outside capture".into()));
        }
        let point = Point {
            x: self.frame.x + x * self.frame.width / self.image_width as f64,
            y: self.frame.y + y * self.frame.height / self.image_height as f64,
        };
        if !point.x.is_finite() || !point.y.is_finite() {
            return Err(AutomationError::Invalid("mapped point".into()));
        }
        Ok(point)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retina_mapping_uses_half_open_bounds_and_rejects_stale_time() {
        let m = ScreenshotCoordinateMapper {
            capture_id: Uuid::new_v4(),
            captured_at: 100.,
            frame: Rect {
                x: -800.,
                y: 50.,
                width: 800.,
                height: 600.,
            },
            image_width: 1600,
            image_height: 1200,
        };
        assert_eq!(
            m.screen_point(m.capture_id, 800., 600., 110., 60.).unwrap(),
            Point { x: -400., y: 350. }
        );
        for (x, y) in [(1600., 0.), (0., 1200.), (-1., 0.), (f64::NAN, 1.)] {
            assert!(m.screen_point(m.capture_id, x, y, 110., 60.).is_err());
        }
        assert!(m.screen_point(m.capture_id, 0., 0., 99., 60.).is_err());
        assert!(m.screen_point(m.capture_id, 0., 0., 161., 60.).is_err());
    }
}
