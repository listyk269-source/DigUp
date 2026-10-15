mod engine;
mod geometry;

use engine::{Device, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
};

const MAX_LINE: usize = 16 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    id: Value,
    op: String,
    path: Option<PathBuf>,
    max_faces: Option<usize>,
}

struct Options {
    models: PathBuf,
    runtime: PathBuf,
    device: Device,
}

fn options(args: impl IntoIterator<Item = String>) -> engine::Result<Options> {
    let mut args = args.into_iter();
    let (mut models, mut runtime, mut device) = (None, None, Device::Auto);
    while let Some(key) = args.next() {
        let value = args.next().ok_or("each option requires a value")?;
        match key.as_str() {
            "--models" if models.is_none()=>models=Some(PathBuf::from(value)),
            "--runtime" if runtime.is_none()=>runtime=Some(PathBuf::from(value)),
            "--device"=>device=Device::parse(&value)?,
            _=>return Err("supported options: --models ABSOLUTE_DIR --runtime ABSOLUTE_LIBRARY --device auto|cpu|gpu"),
        }
    }
    Ok(Options {
        models: models.ok_or("--models is required")?,
        runtime: runtime.ok_or("--runtime is required")?,
        device,
    })
}

enum Line {
    End,
    Data(Vec<u8>),
    TooLong,
}

fn bounded_line(reader: &mut impl BufRead) -> io::Result<Line> {
    let mut result = Vec::with_capacity(1024);
    let mut too_long = false;
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok(if result.is_empty() && !too_long {
                Line::End
            } else if too_long {
                Line::TooLong
            } else {
                Line::Data(result)
            });
        }
        let end = buffer.iter().position(|byte| *byte == b'\n');
        let length = end.map_or(buffer.len(), |v| v + 1);
        if !too_long {
            if result.len() + length > MAX_LINE {
                too_long = true;
                result.clear();
            } else {
                result.extend_from_slice(&buffer[..length]);
            }
        }
        reader.consume(length);
        if end.is_some() {
            return Ok(if too_long {
                Line::TooLong
            } else {
                Line::Data(result)
            });
        }
    }
}

fn parse_request(line: &[u8]) -> engine::Result<Request> {
    let request: Request = serde_json::from_slice(line).map_err(|_| "invalid JSON request")?;
    if !(request.id.is_string() || request.id.is_i64() || request.id.is_u64()) {
        return Err("request id must be a string or integer");
    }
    if request.max_faces.is_some_and(|v| !(1..=32).contains(&v)) {
        return Err("max_faces must be between 1 and 32");
    }
    Ok(request)
}

fn reply(writer: &mut impl Write, value: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn run() -> engine::Result<()> {
    let options = options(std::env::args().skip(1))?;
    let cpu_override = std::env::var_os("DIGUP_CPU_ONLY").is_some_and(|v| v == "1");
    let mut engine = Engine::new(
        &options.models,
        &options.runtime,
        options.device,
        cpu_override,
        std::env::var_os("DIGUP_FACE_DISABLE_GPU").is_some_and(|v| v == "1"),
    )?;
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut input = stdin.lock();
    let mut output = stdout.lock();
    let mut ready = engine.info();
    ready["event"] = json!("ready");
    reply(&mut output, &ready).map_err(|_| "response stream closed")?;
    loop {
        let line = match bounded_line(&mut input).map_err(|_| "request stream failed")? {
            Line::End => break,
            Line::TooLong => {
                reply(
                    &mut output,
                    &json!({"id":null,"ok":false,"error":"request exceeds 16 KiB limit"}),
                )
                .map_err(|_| "response stream closed")?;
                continue;
            }
            Line::Data(line) => line,
        };
        let request = match parse_request(&line) {
            Ok(value) => value,
            Err(error) => {
                reply(&mut output, &json!({"id":null,"ok":false,"error":error}))
                    .map_err(|_| "response stream closed")?;
                continue;
            }
        };
        let response = match request.op.as_str() {
            "info" => engine.info(),
            "quit" => {
                reply(&mut output, &json!({"id":request.id,"ok":true}))
                    .map_err(|_| "response stream closed")?;
                break;
            }
            "analyze" => match request.path {
                Some(path) => match engine.analyze(&path, request.max_faces.unwrap_or(32)) {
                    Ok(value) => {
                        let mut json = serde_json::to_value(value)
                            .map_err(|_| "analysis could not be serialized")?;
                        json["ok"] = json!(true);
                        json
                    }
                    Err(error) => json!({"ok":false,"error":error}),
                },
                None => {
                    json!({"ok":false,"error":"analyze requires an absolute prepared image path"})
                }
            },
            _ => json!({"ok":false,"error":"unsupported operation"}),
        };
        let mut response = response;
        response["id"] = request.id;
        reply(&mut output, &response).map_err(|_| "response stream closed")?;
    }
    Ok(())
}

fn main() {
    std::panic::set_hook(Box::new(|_| {
        eprintln!("face worker native runtime failure")
    }));
    let result = std::panic::catch_unwind(run).unwrap_or(Err("face worker native runtime failure"));
    if let Err(error) = result {
        let _ = reply(&mut io::stdout().lock(), &json!({"ok":false,"error":error}));
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oversized_request_is_drained_without_losing_next_request() {
        let mut bytes = vec![b'x'; MAX_LINE + 2];
        bytes.extend_from_slice(b"\n{\"id\":1,\"op\":\"info\"}\n");
        let mut input = io::Cursor::new(bytes);
        assert!(matches!(bounded_line(&mut input).unwrap(), Line::TooLong));
        let Line::Data(line) = bounded_line(&mut input).unwrap() else {
            panic!()
        };
        assert_eq!(parse_request(&line).unwrap().op, "info");
        assert!(matches!(bounded_line(&mut input).unwrap(), Line::End));
    }
    #[test]
    fn request_bounds_and_unicode_paths() {
        let value =
            json!({"id":"юникод","op":"analyze","path":"C:\\Фото Семья\\лицо.jpg","max_faces":32});
        assert_eq!(
            parse_request(&serde_json::to_vec(&value).unwrap())
                .unwrap()
                .path
                .unwrap(),
            PathBuf::from("C:\\Фото Семья\\лицо.jpg")
        );
        assert!(parse_request(br#"{"id":{},"op":"info"}"#).is_err());
        assert!(parse_request(br#"{"id":1,"op":"analyze","max_faces":33}"#).is_err());
        assert!(parse_request(br#"{"id":1,"op":"info","shell":"bad"}"#).is_err());
    }
    #[test]
    fn options_reject_unknown_and_missing_arguments() {
        assert!(options(["--runtime".into()]).is_err());
        assert!(options(["--download".into(), "yes".into()]).is_err());
    }
}
