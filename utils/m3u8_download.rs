//
// Video downloader from .m3u8 URL
//

use anyhow::Result;
use argh::FromArgs;
use futures::stream::{self, StreamExt};
use reqwest::Client;
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{Read, Write},
    path::Path,
    sync::Arc,
};
use tempfile::tempdir;
use tokio::sync::Semaphore;

#[derive(FromArgs, Debug)]
/// Video downloader from .m3u8 URL
struct Args {
    /// URL of the m3u8 file
    #[argh(positional)]
    m3u8_url: String,

    /// output file name without extension (default: "output")
    #[argh(option, short = 'o', default = "\"output\".to_string()")]
    video_name_without_extension: String,

    /// maximum concurrent downloads (default: 16)
    #[argh(option, short = 'c', default = "16")]
    concurrency: usize,
}

async fn download_segment(
    client: Arc<Client>,
    semaphore: Arc<Semaphore>,
    base_url: &str,
    segment: &str,
) -> Result<Vec<u8>> {
    let _permit = semaphore.acquire().await?;
    let url = if segment.starts_with("http") {
        segment.to_string()
    } else {
        format!("{}{}", base_url, segment)
    };

    let bytes = client.get(&url).send().await?.bytes().await?.to_vec();
    Ok(bytes)
}

fn detect_video_format(file_path: &Path) -> Result<&'static str> {
    let mut file = File::open(file_path)?;
    let mut header = [0u8; 12];
    file.read_exact(&mut header)?;

    if header.starts_with(b"\x00\x00\x00 ftyp") {
        Ok("mp4")
    } else if header[4..12] == *b"ftypavc1" {
        Ok("mp4")
    } else if header.starts_with(b"RIFF") && &header[8..12] == b"AVI " {
        Ok("avi")
    } else if header.starts_with(b"\x1a\x45\xdf\xa3") {
        Ok("webm")
    } else if header.starts_with(b"\x47\x40") {
        Ok("mpeg")
    } else {
        Ok("ts")
    }
}

async fn download_m3u8(m3u8_url: &str, output_name: &str, concurrency: usize) -> Result<()> {
    let client = Arc::new(Client::new());
    let semaphore = Arc::new(Semaphore::new(concurrency));

    let m3u8_content = client.get(m3u8_url).send().await?.text().await?;
    let base_url = m3u8_url.rsplit('/').skip(1).collect::<Vec<_>>().join("/") + "/";

    let segments: Vec<String> = m3u8_content
        .lines()
        .filter(|line| !line.starts_with('#') && !line.is_empty())
        .map(String::from)
        .collect();

    let temp_dir = tempdir()?;
    let temp_path = temp_dir.path();
    println!("found {} segments, downloading...", segments.len());

    // downloading segments in parallel
    let segment_futures = segments.iter().enumerate().map(|(i, segment)| {
        let client = Arc::clone(&client);
        let semaphore = Arc::clone(&semaphore);
        let base_url = base_url.clone();
        let segment = segment.clone();
        let filename = temp_path.join(format!("segment_{:05}.ts", i));

        async move {
            let bytes =
                download_segment_with_retry(client, semaphore, &base_url, &segment, 3).await?;
            let mut file = File::create(&filename)?;
            file.write_all(&bytes)?;
            Ok::<_, anyhow::Error>((i, filename))
        }
    });

    let mut stream = stream::iter(segment_futures).buffer_unordered(concurrency);
    let mut segment_files = BTreeMap::new();

    while let Some(result) = stream.next().await {
        let (i, filename) = result?;
        segment_files.insert(i, filename);
    }

    println!("all segments downloaded, merging...");

    // merging segments in correct order
    let merged_ts = temp_path.join("merged.ts");
    let mut output_file = File::create(&merged_ts)?;
    for (_, filename) in segment_files {
        let mut content = fs::read(filename)?;
        output_file.write_all(&mut content)?;
    }

    // detecting video format and using correct extension
    let format = detect_video_format(&merged_ts)?;
    let output_filename = format!("{}.{}", output_name, format);

    fs::copy(&merged_ts, &output_filename)?;
    println!("download complete, saved as {}", output_filename);

    Ok(())
}

async fn download_segment_with_retry(
    client: Arc<Client>,
    semaphore: Arc<Semaphore>,
    base_url: &str,
    segment: &str,
    retries: usize,
) -> Result<Vec<u8>> {
    for attempt in 0..=retries {
        match download_segment(
            Arc::clone(&client),
            Arc::clone(&semaphore),
            base_url,
            segment,
        )
        .await
        {
            Ok(bytes) => return Ok(bytes),
            Err(e) if attempt == retries => {
                eprintln!("failed after {} retries: {}", retries, e);
                return Err(e);
            }
            Err(e) => {
                eprintln!("attempt {}/{} failed: {}", attempt + 1, retries, e);
                tokio::time::sleep(std::time::Duration::from_secs(1 << attempt)).await;
            }
        }
    }
    unreachable!()
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Args = argh::from_env();
    download_m3u8(
        &args.m3u8_url,
        &args.video_name_without_extension,
        args.concurrency,
    )
    .await?;
    Ok(())
}
