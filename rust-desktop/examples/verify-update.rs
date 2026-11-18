use base64::{engine::general_purpose::STANDARD, Engine};
use minisign_verify::{PublicKey, Signature};
use std::error::Error;
use std::fs;
use std::path::Path;

fn decode(path: &Path) -> Result<String, Box<dyn Error>> {
    Ok(String::from_utf8(
        STANDARD.decode(fs::read_to_string(path)?.trim())?,
    )?)
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let [public_key, package, signature, version] = args.as_slice() else {
        return Err("expected public key, package, signature and release version".into());
    };
    let public_key = PublicKey::decode(&decode(Path::new(public_key))?)?;
    let signature = Signature::decode(&decode(Path::new(signature))?)?;
    let mut data = fs::File::open(package)?;
    let mut verifier = public_key.verify_stream(&signature)?;
    let mut bytes = [0; 32 * 1024];
    loop {
        let count = std::io::Read::read(&mut data, &mut bytes)?;
        if count == 0 {
            break;
        }
        verifier.update(&bytes[..count]);
    }
    verifier.finalize()?;
    let signed_version = signature
        .trusted_comment()
        .split('\t')
        .find_map(|field| field.strip_prefix("version:"));
    if signed_version != version.to_str() {
        return Err("signed version does not match the release version".into());
    }
    Ok(())
}
