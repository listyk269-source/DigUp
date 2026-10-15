use crate::geometry::{aligned_rgb, nms, normalize, Detection};
use image::{
    imageops::FilterType, DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits, RgbImage,
};
use ort::{
    execution_providers::DirectMLExecutionProvider, logging::LogLevel, session::Session,
    value::Tensor,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{BufReader, Read},
    path::{Path, PathBuf},
};

pub const MODEL_ID: &str = "yunet-2023mar-sface-2021dec-rgbraw-align112-v1";
pub const DIMENSION: usize = 128;
const INPUT: usize = 640;
const DETECTION_THRESHOLD: f32 = 0.75;
const YUNET: &str = "face_detection_yunet_2023mar.onnx";
const SFACE: &str = "face_recognition_sface_2021dec.onnx";
const YUNET_SHA256: &str = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4";
const SFACE_SHA256: &str = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79";

pub type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Device {
    Auto,
    Cpu,
    Gpu,
}

impl Device {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "auto" => Ok(Self::Auto),
            "cpu" => Ok(Self::Cpu),
            "gpu" => Ok(Self::Gpu),
            _ => Err("device must be auto, cpu, or gpu"),
        }
    }
}

#[derive(Serialize)]
pub struct Face {
    pub bbox: [f32; 4],
    pub landmarks: [f32; 10],
    pub score: f32,
    /// Heuristic quality for ranking, not the probability of an identity.
    pub quality: f32,
    pub embedding: Vec<f32>,
}

#[derive(Serialize)]
pub struct Analysis {
    pub model_id: &'static str,
    pub width: u32,
    pub height: u32,
    pub device: &'static str,
    pub backend: &'static str,
    pub fallback_reason: Option<&'static str>,
    pub faces: Vec<Face>,
}

pub struct Engine {
    detector: Session,
    recognizer: Session,
    models: PathBuf,
    gpu: bool,
    gpu_device_index: i32,
    pub fallback_reason: Option<&'static str>,
}

impl Engine {
    pub fn new(
        models: &Path,
        runtime: &Path,
        requested: Device,
        cpu_override: bool,
        disable_gpu: bool,
    ) -> Result<Self> {
        if !models.is_absolute() || !runtime.is_absolute() {
            return Err("models and runtime paths must be absolute");
        }
        if !runtime.is_file() {
            return Err("packaged ONNX Runtime library is missing");
        }
        verify_model(&models.join(YUNET), YUNET_SHA256)?;
        verify_model(&models.join(SFACE), SFACE_SHA256)?;
        restrict_library_search(runtime)?;
        let runtime = runtime.to_str().ok_or("runtime path is not Unicode")?;
        ort::init_from(runtime)
            .with_name("DigUp local faces")
            .with_telemetry(false)
            .commit()
            .map_err(|_| "ONNX Runtime could not be initialized")?;
        let gpu = requested != Device::Cpu && !cpu_override && !disable_gpu;
        let gpu_device_index = if gpu {
            std::env::var("DIGUP_FACE_GPU_DEVICE")
                .ok()
                .map(|value| value.parse::<i32>())
                .transpose()
                .map_err(|_| "DIGUP_FACE_GPU_DEVICE must be an integer from 0 to 31")?
                .unwrap_or(0)
        } else {
            0
        };
        if !(0..=31).contains(&gpu_device_index) {
            return Err("DIGUP_FACE_GPU_DEVICE must be an integer from 0 to 31");
        }
        let selected_reason = if cpu_override {
            Some("DIGUP_CPU_ONLY override")
        } else if disable_gpu && requested != Device::Cpu {
            Some("DirectML disabled by DIGUP_FACE_DISABLE_GPU; CPU fallback")
        } else {
            None
        };
        match Self::sessions(models, gpu, gpu_device_index) {
            Ok((detector, recognizer)) => Ok(Self {
                detector,
                recognizer,
                models: models.into(),
                gpu,
                gpu_device_index,
                fallback_reason: selected_reason,
            }),
            Err(_) if gpu => {
                let (detector, recognizer) = Self::sessions(models, false, 0)?;
                Ok(Self {
                    detector,
                    recognizer,
                    models: models.into(),
                    gpu: false,
                    gpu_device_index,
                    fallback_reason: Some(
                        "DirectML unavailable or model initialization failed; CPU fallback",
                    ),
                })
            }
            Err(error) => Err(error),
        }
    }

    fn sessions(models: &Path, gpu: bool, gpu_device_index: i32) -> Result<(Session, Session)> {
        let create = |path: &Path| -> Result<Session> {
            let mut builder = Session::builder()
                .map_err(|_| "inference session could not be created")?
                .with_intra_threads(2)
                .map_err(|_| "inference thread setup failed")?
                .with_parallel_execution(false)
                .map_err(|_| "sequential inference setup failed")?
                .with_memory_pattern(false)
                .map_err(|_| "inference memory setup failed")?
                .with_log_level(LogLevel::Error)
                .map_err(|_| "inference logging setup failed")?;
            if gpu {
                builder = builder
                    .with_execution_providers([DirectMLExecutionProvider::default()
                        .with_device_id(gpu_device_index)
                        .build()
                        .error_on_failure()])
                    .map_err(|_| "DirectML execution provider is unavailable")?;
            }
            builder
                .commit_from_file(path)
                .map_err(|_| "face model could not be loaded")
        };
        Ok((create(&models.join(YUNET))?, create(&models.join(SFACE))?))
    }

    pub fn info(&self) -> serde_json::Value {
        serde_json::json!({"ok":true,"model_id":MODEL_ID,"dimension":DIMENSION,
            "device":if self.gpu {"gpu"}else{"cpu"},"backend":if self.gpu {"directml"}else{"cpu"},
            "gpu_device_index":if self.gpu {Some(self.gpu_device_index)}else{None},
            "fallback_reason":self.fallback_reason,"detection_threshold":DETECTION_THRESHOLD,
            "max_faces":32,"input_size":640,"runtime_info":ort::info()})
    }

    pub fn analyze(&mut self, path: &Path, maximum: usize) -> Result<Analysis> {
        let image = read_image(path)?;
        let first = self.infer(&image, maximum);
        let faces = match first {
            Err(_) if self.gpu => {
                // Never report successful GPU inference after an EP failure.
                // Recreate both sessions explicitly on CPU and retry once.
                let (detector, recognizer) = Self::sessions(&self.models, false, 0)?;
                self.detector = detector;
                self.recognizer = recognizer;
                self.gpu = false;
                self.fallback_reason = Some("DirectML inference failed; CPU fallback");
                self.infer(&image, maximum)?
            }
            value => value?,
        };
        Ok(Analysis {
            model_id: MODEL_ID,
            width: image.width(),
            height: image.height(),
            device: if self.gpu { "gpu" } else { "cpu" },
            backend: if self.gpu { "directml" } else { "cpu" },
            fallback_reason: self.fallback_reason,
            faces,
        })
    }

    fn infer(&mut self, image: &RgbImage, maximum: usize) -> Result<Vec<Face>> {
        let (input, scale_x, scale_y) = detector_input(image);
        let input = Tensor::from_array(([1, 3, INPUT, INPUT], input))
            .map_err(|_| "detector tensor could not be created")?;
        let output = self
            .detector
            .run(ort::inputs![input])
            .map_err(|_| "face detection failed")?;
        let mut detections = Vec::new();
        for stride in [8, 16, 32] {
            let rows = INPUT / stride;
            let extract = |name: String, count: usize| -> Result<&[f32]> {
                let value = output.get(&name).ok_or("detector output is missing")?;
                let (_, values) = value
                    .try_extract_tensor::<f32>()
                    .map_err(|_| "invalid detector output type")?;
                if values.len() != rows * rows * count {
                    return Err("invalid detector output dimensions");
                }
                Ok(values)
            };
            let cls = extract(format!("cls_{stride}"), 1)?;
            let obj = extract(format!("obj_{stride}"), 1)?;
            let boxes = extract(format!("bbox_{stride}"), 4)?;
            let kps = extract(format!("kps_{stride}"), 10)?;
            for index in 0..rows * rows {
                let score = (cls[index].clamp(0.0, 1.0) * obj[index].clamp(0.0, 1.0)).sqrt();
                if !score.is_finite() || score < DETECTION_THRESHOLD {
                    continue;
                }
                let col = (index % rows) as f32;
                let row = (index / rows) as f32;
                let stride = stride as f32;
                let width = boxes[index * 4 + 2].exp() * stride / scale_x;
                let height = boxes[index * 4 + 3].exp() * stride / scale_y;
                let x = (col + boxes[index * 4]) * stride / scale_x - width / 2.0;
                let y = (row + boxes[index * 4 + 1]) * stride / scale_y - height / 2.0;
                let mut landmarks = [0.0; 10];
                for i in 0..5 {
                    landmarks[i * 2] = (col + kps[index * 10 + i * 2]) * stride / scale_x;
                    landmarks[i * 2 + 1] = (row + kps[index * 10 + i * 2 + 1]) * stride / scale_y;
                }
                if ![x, y, width, height]
                    .iter()
                    .chain(landmarks.iter())
                    .all(|v| v.is_finite())
                    || width < 12.0
                    || height < 12.0
                {
                    continue;
                }
                if x >= image.width() as f32
                    || y >= image.height() as f32
                    || x + width <= 0.0
                    || y + height <= 0.0
                {
                    continue;
                }
                detections.push(Detection {
                    bbox: [x, y, width, height],
                    landmarks,
                    score,
                });
            }
        }
        drop(output);
        let mut faces = Vec::new();
        for detection in nms(detections, maximum) {
            let Some(crop) = aligned_rgb(image, &detection.landmarks) else {
                continue;
            };
            let input = Tensor::from_array(([1, 3, 112, 112], crop))
                .map_err(|_| "recognizer tensor could not be created")?;
            let output = self
                .recognizer
                .run(ort::inputs![input])
                .map_err(|_| "face recognition failed")?;
            let (_, values) = output[0]
                .try_extract_tensor::<f32>()
                .map_err(|_| "invalid face embedding type")?;
            if values.len() != DIMENSION {
                return Err("face embedding dimension is incompatible");
            }
            let mut embedding = values.to_vec();
            if !normalize(&mut embedding) {
                continue;
            }
            let width = image.width() as f32;
            let height = image.height() as f32;
            let [x, y, w, h] = detection.bbox;
            let left = x.clamp(0.0, width);
            let top = y.clamp(0.0, height);
            let bbox = [
                left / width,
                top / height,
                ((x + w).clamp(0.0, width) - left) / width,
                ((y + h).clamp(0.0, height) - top) / height,
            ];
            let mut landmarks = detection.landmarks;
            for pair in landmarks.chunks_exact_mut(2) {
                pair[0] = (pair[0] / width).clamp(0.0, 1.0);
                pair[1] = (pair[1] / height).clamp(0.0, 1.0);
            }
            faces.push(Face {
                bbox,
                landmarks,
                score: detection.score,
                quality: (w.min(h) / 80.0).clamp(0.0, 1.0) * detection.score,
                embedding,
            });
        }
        Ok(faces)
    }
}

fn detector_input(image: &RgbImage) -> (Vec<f32>, f32, f32) {
    let scale = INPUT as f32 / image.width().max(image.height()) as f32;
    let width = ((image.width() as f32 * scale).round() as u32).clamp(1, INPUT as u32);
    let height = ((image.height() as f32 * scale).round() as u32).clamp(1, INPUT as u32);
    let resized = image::imageops::resize(image, width, height, FilterType::Triangle);
    let mut input = vec![0.0; 3 * INPUT * INPUT];
    for (x, y, pixel) in resized.enumerate_pixels() {
        for channel in 0..3 {
            input[channel * INPUT * INPUT + y as usize * INPUT + x as usize] =
                pixel[2 - channel] as f32;
        }
    }
    (
        input,
        width as f32 / image.width() as f32,
        height as f32 / image.height() as f32,
    )
}

fn read_image(path: &Path) -> Result<RgbImage> {
    if !path.is_absolute() {
        return Err("image path must be absolute");
    }
    let file = File::open(path).map_err(|_| "prepared image is inaccessible")?;
    let metadata = file
        .metadata()
        .map_err(|_| "prepared image metadata is inaccessible")?;
    if !metadata.is_file() || metadata.len() > 64 * 1024 * 1024 {
        return Err("prepared image exceeds the 64 MiB input limit or is not a regular file");
    }
    let mut reader = ImageReader::new(BufReader::new(file))
        .with_guessed_format()
        .map_err(|_| "prepared image format could not be read")?;
    if !matches!(reader.format(), Some(ImageFormat::Png | ImageFormat::Jpeg)) {
        return Err("prepared image must be PNG or JPEG");
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(192 * 1024 * 1024);
    reader.limits(limits);
    let decoder = reader
        .into_decoder()
        .map_err(|_| "prepared image is damaged or exceeds decoder limits")?;
    let (width, height) = decoder.dimensions();
    if width == 0
        || height == 0
        || u64::from(width) * u64::from(height) > 16 * 1024 * 1024
        || decoder.total_bytes() > 192 * 1024 * 1024
    {
        return Err("prepared image exceeds the 16 megapixel input limit");
    }
    DynamicImage::from_decoder(decoder)
        .map(DynamicImage::into_rgb8)
        .map_err(|_| "prepared image is damaged or exceeds decoder limits")
}

fn verify_model(path: &Path, expected: &str) -> Result<()> {
    let mut file = File::open(path)
        .map_err(|_| "face model is missing or inaccessible; download the verified face models")?;
    if file
        .metadata()
        .map_err(|_| "face model metadata is inaccessible")?
        .len()
        > 64 * 1024 * 1024
    {
        return Err("face model exceeds the size limit");
    }
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| "face model could not be verified")?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    if format!("{:x}", hash.finalize()) != expected {
        return Err("face model SHA-256 verification failed; download the verified models again");
    }
    Ok(())
}

#[cfg(windows)]
fn restrict_library_search(runtime: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::System::LibraryLoader::{
        AddDllDirectory, SetDefaultDllDirectories, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
    };
    let parent = runtime.parent().ok_or("runtime directory is missing")?;
    let mut wide: Vec<u16> = parent.as_os_str().encode_wide().collect();
    wide.push(0);
    unsafe {
        if SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) == 0
            || AddDllDirectory(wide.as_ptr()).is_null()
        {
            return Err("secure packaged DLL lookup could not be configured");
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn restrict_library_search(_: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;
    #[test]
    fn yunet_is_bgr_and_padding_does_not_stretch() {
        let image = RgbImage::from_pixel(320, 160, Rgb([10, 20, 30]));
        let (input, sx, sy) = detector_input(&image);
        assert_eq!((sx, sy), (2.0, 2.0));
        assert_eq!(input[0], 30.0);
        assert_eq!(input[INPUT * INPUT], 20.0);
        assert_eq!(input[2 * INPUT * INPUT], 10.0);
        assert_eq!(input[400 * INPUT], 0.0);
    }
    #[test]
    fn relative_and_unsupported_inputs_fail_before_inference() {
        assert!(read_image(Path::new("relative.png")).is_err());
        assert_eq!(Device::parse("gpu").unwrap(), Device::Gpu);
        assert!(Device::parse("cuda:0").is_err());
    }
}
