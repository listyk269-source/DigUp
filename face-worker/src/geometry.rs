//! YuNet decoding geometry and the five-point SFace alignment.
use image::{Rgb, RgbImage};

pub const TARGET: [[f32; 2]; 5] = [
    [38.2946, 51.6963],
    [73.5318, 51.5014],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.2041],
];

#[derive(Clone, Debug)]
pub struct Detection {
    pub bbox: [f32; 4],
    pub landmarks: [f32; 10],
    pub score: f32,
}

pub fn intersection_over_union(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    let w = ((a[0] + a[2]).min(b[0] + b[2]) - a[0].max(b[0])).max(0.0);
    let h = ((a[1] + a[3]).min(b[1] + b[3]) - a[1].max(b[1])).max(0.0);
    let intersection = w * h;
    let union = a[2] * a[3] + b[2] * b[3] - intersection;
    if union > 0.0 {
        intersection / union
    } else {
        0.0
    }
}

pub fn nms(mut detections: Vec<Detection>, maximum: usize) -> Vec<Detection> {
    if maximum == 0 {
        return Vec::new();
    }
    detections.sort_by(|a, b| b.score.total_cmp(&a.score));
    // 8,400 grid cells at input 640. Bound work independently of model data.
    detections.truncate(5000);
    let mut result: Vec<Detection> = Vec::with_capacity(maximum);
    for detection in detections {
        if result
            .iter()
            .all(|kept| intersection_over_union(&kept.bbox, &detection.bbox) <= 0.3)
        {
            result.push(detection);
            if result.len() == maximum {
                break;
            }
        }
    }
    result
}

/// Least-squares orientation-preserving similarity, source -> canonical face.
/// Unlike an affine fit this cannot introduce shear or nonuniform face scaling.
pub fn similarity(source: &[f32; 10]) -> Option<[f32; 4]> {
    if !source.iter().all(|v| v.is_finite()) {
        return None;
    }
    let (mut sx, mut sy, mut dx, mut dy) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
    for i in 0..5 {
        sx += source[i * 2] as f64;
        sy += source[i * 2 + 1] as f64;
        dx += TARGET[i][0] as f64;
        dy += TARGET[i][1] as f64;
    }
    (sx, sy, dx, dy) = (sx / 5.0, sy / 5.0, dx / 5.0, dy / 5.0);
    let (mut norm, mut dot, mut cross) = (0.0, 0.0, 0.0);
    for i in 0..5 {
        let x = source[i * 2] as f64 - sx;
        let y = source[i * 2 + 1] as f64 - sy;
        let u = TARGET[i][0] as f64 - dx;
        let v = TARGET[i][1] as f64 - dy;
        norm += x * x + y * y;
        dot += x * u + y * v;
        cross += x * v - y * u;
    }
    if norm < 1e-8 {
        return None;
    }
    let a = dot / norm;
    let b = cross / norm;
    let result = [
        a as f32,
        b as f32,
        (dx - a * sx + b * sy) as f32,
        (dy - b * sx - a * sy) as f32,
    ];
    (result.iter().all(|v| v.is_finite()) && a * a + b * b > 1e-12).then_some(result)
}

/// Inverse-map with bilinear sampling and constant black outside the image,
/// matching OpenCV warpAffine's default border mode. Output is planar RGB raw
/// 0..255, as SFace's graph itself performs its input normalization.
pub fn aligned_rgb(image: &RgbImage, landmarks: &[f32; 10]) -> Option<Vec<f32>> {
    let [a, b, tx, ty] = similarity(landmarks)?;
    let determinant = a * a + b * b;
    let mut tensor = vec![0.0; 3 * 112 * 112];
    for y in 0..112 {
        for x in 0..112 {
            let u = x as f32 - tx;
            let v = y as f32 - ty;
            let source_x = (a * u + b * v) / determinant;
            let source_y = (-b * u + a * v) / determinant;
            let pixel = bilinear(image, source_x, source_y);
            for channel in 0..3 {
                tensor[channel * 112 * 112 + y * 112 + x] = pixel[channel];
            }
        }
    }
    Some(tensor)
}

fn bilinear(image: &RgbImage, x: f32, y: f32) -> [f32; 3] {
    let x0 = x.floor() as i32;
    let y0 = y.floor() as i32;
    let fx = x - x0 as f32;
    let fy = y - y0 as f32;
    let mut result = [0.0; 3];
    for (px, py, weight) in [
        (x0, y0, (1.0 - fx) * (1.0 - fy)),
        (x0 + 1, y0, fx * (1.0 - fy)),
        (x0, y0 + 1, (1.0 - fx) * fy),
        (x0 + 1, y0 + 1, fx * fy),
    ] {
        if px >= 0 && py >= 0 && px < image.width() as i32 && py < image.height() as i32 {
            let Rgb(pixel) = *image.get_pixel(px as u32, py as u32);
            for channel in 0..3 {
                result[channel] += pixel[channel] as f32 * weight;
            }
        }
    }
    result
}

pub fn normalize(values: &mut [f32]) -> bool {
    if values.is_empty() || !values.iter().all(|v| v.is_finite()) {
        return false;
    }
    let norm = values
        .iter()
        .map(|v| (*v as f64).powi(2))
        .sum::<f64>()
        .sqrt();
    if norm <= 1e-12 {
        return false;
    }
    for value in values {
        *value = (*value as f64 / norm) as f32;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(bbox: [f32; 4], score: f32) -> Detection {
        Detection {
            bbox,
            score,
            landmarks: [0.0; 10],
        }
    }

    #[test]
    fn nms_keeps_distinct_faces_and_highest_duplicate() {
        let kept = nms(
            vec![
                candidate([10.0, 10.0, 40.0, 40.0], 0.8),
                candidate([11.0, 11.0, 40.0, 40.0], 0.95),
                candidate([100.0, 10.0, 40.0, 40.0], 0.9),
            ],
            32,
        );
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].score, 0.95);
        assert_eq!(nms(kept, 1).len(), 1);
    }

    #[test]
    fn rotated_scaled_alignment_recovers_canonical_points() {
        let a = 1.8_f32 * 0.3_f32.cos();
        let b = 1.8_f32 * 0.3_f32.sin();
        let mut source = [0.0; 10];
        for (i, point) in TARGET.iter().enumerate() {
            source[i * 2] = a * point[0] - b * point[1] + 100.0;
            source[i * 2 + 1] = b * point[0] + a * point[1] + 20.0;
        }
        let [a, b, tx, ty] = similarity(&source).unwrap();
        for (i, point) in TARGET.iter().enumerate() {
            assert!((a * source[i * 2] - b * source[i * 2 + 1] + tx - point[0]).abs() < 0.001);
            assert!((b * source[i * 2] + a * source[i * 2 + 1] + ty - point[1]).abs() < 0.001);
        }
        assert!(similarity(&[1.0; 10]).is_none());
    }

    #[test]
    fn sface_input_is_rgb_raw_not_bgr_or_scaled() {
        let image = RgbImage::from_pixel(112, 112, Rgb([23, 51, 217]));
        let source: Vec<_> = TARGET.into_iter().flatten().collect();
        let tensor = aligned_rgb(&image, source.as_slice().try_into().unwrap()).unwrap();
        assert!((tensor[50 * 112 + 50] - 23.0).abs() < 0.001);
        assert!((tensor[112 * 112 + 50 * 112 + 50] - 51.0).abs() < 0.001);
        assert!((tensor[2 * 112 * 112 + 50 * 112 + 50] - 217.0).abs() < 0.001);
    }

    #[test]
    fn l2_rejects_invalid_vectors() {
        let mut v = [3.0, 4.0];
        assert!(normalize(&mut v));
        assert_eq!(v, [0.6, 0.8]);
        assert!(!normalize(&mut [0.0; 128]));
        assert!(!normalize(&mut [f32::NAN]));
    }
}
