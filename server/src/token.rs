//! Session tokens.
//!
//! A pilot proves who they are to the meta-layer once, and carries the answer
//! to whatever arena they join. The arena never asks anybody: it checks a
//! signature and a clock, which is what keeps identity off the join path and
//! lets the meta-layer be down without stopping play.
//!
//! docs/architecture/meta-layer.md is the design. The short version is that
//! this is the only thing an arena trusts about a pilot, so it carries
//! everything an arena needs: who they are, what kind of thing they are, what
//! to call them, and what their rating was when the token was minted.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

/// Bumped when the payload layout changes. A token from a previous version is
/// refused rather than misread, the same rule the client wire follows.
const VERSION: u8 = 2;

/// How long a token is good for. Short enough that a ban lands within one
/// lifetime, since the meta-layer enforces bans by refusing to mint, and long
/// enough that a session does not spend its time logging in.
pub const LIFETIME_SECS: u64 = 15 * 60;

/// What is flying the seat. This is the account's own kind rather than
/// anything the client asserted, which is what makes the roster label worth
/// believing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Human,
    /// Ours, flown by the bot server under a pool credential. Only these may
    /// anchor the rating ladder.
    HouseBot,
    /// Somebody else's, declared honestly and rated normally, anchoring
    /// nothing because we have never seen the code.
    ThirdPartyBot,
}

impl Kind {
    fn to_byte(self) -> u8 {
        match self {
            Kind::Human => 0,
            Kind::HouseBot => 1,
            Kind::ThirdPartyBot => 2,
        }
    }
    fn from_byte(b: u8) -> Option<Kind> {
        match b {
            0 => Some(Kind::Human),
            1 => Some(Kind::HouseBot),
            2 => Some(Kind::ThirdPartyBot),
            _ => None,
        }
    }
    pub fn is_bot(self) -> bool {
        !matches!(self, Kind::Human)
    }
}

/// What a client is told about a seat, and the whole of what one player knows
/// about another. Three values rather than two, because a guest is genuinely
/// unknown and saying so is more honest than guessing human.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Label {
    /// A claimed human account.
    Human,
    /// Ours.
    HouseBot,
    /// Declared by somebody else.
    ThirdPartyBot,
    /// A guest. Most are humans in their first session, which is why this is a
    /// statement about what we know rather than an accusation.
    Unknown,
}

impl Label {
    pub fn to_byte(self) -> u8 {
        match self {
            Label::Unknown => 0,
            Label::Human => 1,
            Label::HouseBot => 2,
            Label::ThirdPartyBot => 3,
        }
    }
}

/// A pilot's standing in one mode class, as of when the token was minted.
#[derive(Clone, Debug, PartialEq)]
pub struct ClassRating {
    pub class: String,
    pub rating: f64,
    pub games: u32,
}

/// The contents of a token, once the signature has been checked.
#[derive(Clone, Debug, PartialEq)]
pub struct Claims {
    pub account: u64,
    pub kind: Kind,
    /// Whether the account has a credential beyond the secret its client
    /// holds. This plus `kind` is the whole of what the label is derived from.
    pub claimed: bool,
    pub name: String,
    pub expires: u64,
    pub ratings: Vec<ClassRating>,
    /// What this account may slot, over the core's flat kit space, as a
    /// ceiling per slot with 255 meaning "the hull decides".
    ///
    /// It rides in the token for the same reason a rating does: an arena
    /// checks a kit against it at the door, and admission has to be
    /// arithmetic rather than a network call. What a pilot has *chosen* is
    /// not here, because that changes in the hangar between matches and this
    /// only changes when something is bought.
    ///
    /// Empty from an older meta-layer, which an arena reads as the baseline
    /// rather than as an account that owns nothing.
    pub entitlements: Vec<u8>,
}

impl Claims {
    /// The label a seat wears, derived rather than asserted. A client cannot
    /// dress a guest as a human without a signature it does not have.
    pub fn label(&self) -> Label {
        match self.kind {
            Kind::HouseBot => Label::HouseBot,
            Kind::ThirdPartyBot => Label::ThirdPartyBot,
            Kind::Human if self.claimed => Label::Human,
            Kind::Human => Label::Unknown,
        }
    }

    pub fn rating_in(&self, class: &str) -> Option<&ClassRating> {
        self.ratings.iter().find(|r| r.class == class)
    }

    fn payload(&self) -> Vec<u8> {
        let mut p = vec![VERSION, self.kind.to_byte(), u8::from(self.claimed)];
        p.extend_from_slice(&self.account.to_le_bytes());
        p.extend_from_slice(&self.expires.to_le_bytes());
        push_str(&mut p, &self.name);
        // Every class the account has played, so a pilot's standing survives
        // moving between zones without the arena asking anybody anything.
        // Classes are few, and this is what makes one career span a fleet.
        p.push(self.ratings.len().min(255) as u8);
        for r in self.ratings.iter().take(255) {
            push_str(&mut p, &r.class);
            p.extend_from_slice(&(r.rating.round().clamp(-32768.0, 32767.0) as i16).to_le_bytes());
            p.push(r.games.min(255) as u8);
        }
        p.push(self.entitlements.len().min(255) as u8);
        p.extend_from_slice(&self.entitlements[..self.entitlements.len().min(255)]);
        p
    }
}

fn push_str(out: &mut Vec<u8>, s: &str) {
    let b = s.as_bytes();
    let n = b.len().min(255);
    out.push(n as u8);
    out.extend_from_slice(&b[..n]);
}

fn take_str(data: &[u8], at: &mut usize) -> Option<String> {
    let n = *data.get(*at)? as usize;
    *at += 1;
    let s = data.get(*at..*at + n)?;
    *at += n;
    Some(String::from_utf8_lossy(s).to_string())
}

/// Why a token was not accepted. The arena tells a client which, because
/// "expired" means log in again and the rest mean something is wrong.
#[derive(Debug, PartialEq)]
pub enum Bad {
    Malformed,
    Version,
    Signature,
    Expired,
}

/// Sign claims into a token. Only the meta-layer holds the signing key.
pub fn mint(key: &SigningKey, claims: &Claims) -> String {
    let payload = claims.payload();
    let sig = key.sign(&payload);
    let mut raw = payload;
    raw.extend_from_slice(&sig.to_bytes());
    b64_encode(&raw)
}

/// Check a token and read it. Every arena can do this with the verifying key
/// the catalog carries, which is the whole point: admission is arithmetic, not
/// a network call.
pub fn verify(key: &VerifyingKey, token: &str, now: u64) -> Result<Claims, Bad> {
    let raw = b64_decode(token).ok_or(Bad::Malformed)?;
    if raw.len() < 64 + 20 {
        return Err(Bad::Malformed);
    }
    let (payload, sig) = raw.split_at(raw.len() - 64);
    // Version before signature, so a token from a future build is reported as
    // a version problem rather than as a forgery.
    if payload[0] != VERSION {
        return Err(Bad::Version);
    }
    let sig: [u8; 64] = sig.try_into().map_err(|_| Bad::Malformed)?;
    key.verify(payload, &Signature::from_bytes(&sig))
        .map_err(|_| Bad::Signature)?;

    let kind = Kind::from_byte(payload[1]).ok_or(Bad::Malformed)?;
    let claimed = payload[2] != 0;
    let account = u64::from_le_bytes(
        payload
            .get(3..11)
            .ok_or(Bad::Malformed)?
            .try_into()
            .unwrap(),
    );
    let expires = u64::from_le_bytes(
        payload
            .get(11..19)
            .ok_or(Bad::Malformed)?
            .try_into()
            .unwrap(),
    );
    let mut at = 19;
    let name = take_str(payload, &mut at).ok_or(Bad::Malformed)?;
    let n = *payload.get(at).ok_or(Bad::Malformed)? as usize;
    at += 1;
    let mut ratings = Vec::with_capacity(n);
    for _ in 0..n {
        let class = take_str(payload, &mut at).ok_or(Bad::Malformed)?;
        let r = i16::from_le_bytes(
            payload
                .get(at..at + 2)
                .ok_or(Bad::Malformed)?
                .try_into()
                .unwrap(),
        );
        at += 2;
        let games = *payload.get(at).ok_or(Bad::Malformed)? as u32;
        at += 1;
        ratings.push(ClassRating {
            class,
            rating: r as f64,
            games,
        });
    }

    let n = *payload.get(at).ok_or(Bad::Malformed)? as usize;
    at += 1;
    let entitlements = payload.get(at..at + n).ok_or(Bad::Malformed)?.to_vec();

    // Expiry last. A signature check on an expired token still tells us the
    // token was ours, which is the difference between "log in again" and
    // "something is forging tokens".
    if now >= expires {
        return Err(Bad::Expired);
    }
    Ok(Claims {
        account,
        kind,
        claimed,
        name,
        expires,
        ratings,
        entitlements,
    })
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The signing key, from an environment variable holding 64 hex characters.
/// Generated by `vectorwake-server metakey`, never typed.
pub fn signing_key_from_hex(hex: &str) -> Option<SigningKey> {
    let bytes = from_hex(hex.trim())?;
    let bytes: [u8; 32] = bytes.try_into().ok()?;
    Some(SigningKey::from_bytes(&bytes))
}

pub fn verifying_key_from_hex(hex: &str) -> Option<VerifyingKey> {
    let bytes = from_hex(hex.trim())?;
    let bytes: [u8; 32] = bytes.try_into().ok()?;
    VerifyingKey::from_bytes(&bytes).ok()
}

pub fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

/// base64url without padding, because a token travels in JSON and in a URL and
/// should need escaping in neither.
fn b64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

fn b64_decode(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(s)
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> SigningKey {
        // A fixed key, so a failure is a failure rather than a coin flip.
        SigningKey::from_bytes(&[7u8; 32])
    }

    fn claims() -> Claims {
        Claims {
            account: 12345,
            kind: Kind::Human,
            claimed: true,
            name: "Vesper 47".into(),
            expires: 1000,
            ratings: vec![
                ClassRating {
                    class: "arena".into(),
                    rating: 1337.0,
                    games: 42,
                },
                ClassRating {
                    class: "warzone".into(),
                    rating: 1100.0,
                    games: 3,
                },
            ],
            entitlements: vec![6, 6, 6, 6, 6, 1, 1],
        }
    }

    #[test]
    fn a_minted_token_reads_back_exactly() {
        let k = key();
        let t = mint(&k, &claims());
        let got = verify(&k.verifying_key(), &t, 999).expect("verifies");
        assert_eq!(got, claims());
    }

    #[test]
    fn a_tampered_token_is_refused() {
        let k = key();
        let t = mint(&k, &claims());
        // Flip a bit in the middle of the payload, which is where the account
        // id lives. This is the attack the whole scheme exists to stop.
        let mut raw = b64_decode(&t).unwrap();
        raw[5] ^= 1;
        let forged = b64_encode(&raw);
        assert_eq!(
            verify(&k.verifying_key(), &forged, 999),
            Err(Bad::Signature)
        );
    }

    #[test]
    fn another_key_does_not_verify() {
        let t = mint(&key(), &claims());
        let other = SigningKey::from_bytes(&[9u8; 32]);
        assert_eq!(verify(&other.verifying_key(), &t, 999), Err(Bad::Signature));
    }

    #[test]
    fn an_expired_token_is_expired_rather_than_forged() {
        let k = key();
        let t = mint(&k, &claims());
        assert_eq!(verify(&k.verifying_key(), &t, 1000), Err(Bad::Expired));
    }

    #[test]
    fn rubbish_is_malformed() {
        let k = key().verifying_key();
        assert_eq!(verify(&k, "not a token", 1), Err(Bad::Malformed));
        assert_eq!(verify(&k, "", 1), Err(Bad::Malformed));
    }

    /// The label is the answer to principle two, so it gets its own test: a
    /// client cannot assert it, and each account shape produces exactly one.
    #[test]
    fn labels_come_from_the_account_shape() {
        let mut c = claims();
        assert_eq!(c.label(), Label::Human);
        c.claimed = false;
        assert_eq!(c.label(), Label::Unknown, "a guest is unknown, not human");
        c.kind = Kind::HouseBot;
        assert_eq!(
            c.label(),
            Label::HouseBot,
            "a bot is a bot whether or not it claimed"
        );
        c.kind = Kind::ThirdPartyBot;
        assert_eq!(c.label(), Label::ThirdPartyBot);
    }

    #[test]
    fn a_pilot_carries_every_class_they_have_played() {
        let k = key();
        let got = verify(&k.verifying_key(), &mint(&k, &claims()), 999).unwrap();
        assert_eq!(got.rating_in("arena").unwrap().rating, 1337.0);
        assert_eq!(got.rating_in("warzone").unwrap().games, 3);
        assert!(
            got.rating_in("hockey").is_none(),
            "a class never played has no rating"
        );
    }

    #[test]
    fn a_guest_with_no_history_still_makes_a_token() {
        let k = key();
        let c = Claims {
            account: 1,
            kind: Kind::Human,
            claimed: false,
            name: "Talon 3".into(),
            expires: 100,
            ratings: vec![],
            entitlements: Vec::new(),
        };
        let got = verify(&k.verifying_key(), &mint(&k, &c), 1).unwrap();
        assert_eq!(got, c);
        assert_eq!(got.label(), Label::Unknown);
    }

    #[test]
    fn hex_round_trips() {
        let k = key();
        let hex = to_hex(&k.to_bytes());
        assert_eq!(signing_key_from_hex(&hex).unwrap().to_bytes(), k.to_bytes());
        let vhex = to_hex(k.verifying_key().as_bytes());
        assert_eq!(
            verifying_key_from_hex(&vhex).unwrap().to_bytes(),
            k.verifying_key().to_bytes()
        );
        assert!(verifying_key_from_hex("nonsense").is_none());
    }
}
