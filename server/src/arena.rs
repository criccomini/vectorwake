use std::collections::HashMap;
use std::sync::OnceLock;

use tokio_tungstenite::tungstenite::Message;

use crate::delivery::next_nonzero;
use crate::protocol::*;
use crate::room::*;
use crate::{
    ai, calibrate, catalog, config, fleet, meta, modes, pilot, pilots, rating, reporting_enabled,
    select, sim, spool, token, DEFAULT_MAX_PLAYERS, DEFAULT_MAX_WATCHERS,
};

fn account_entitlements(claimed: &[u8]) -> [u8; sim::SLOT_COUNT] {
    let mut entitlements = sim::World::base_entitlements();
    for (slot, n) in claimed.iter().enumerate() {
        if let Some(c) = entitlements.get_mut(slot) {
            *c = (*c).max(*n);
        }
    }
    entitlements
}

/// This process: one arena server, serving one zone, holding that zone's
/// rooms.
///
/// The three words are not interchangeable and the vocabulary section of
/// docs/architecture/zones-and-arenas.md is the authority on them. A zone is a
/// named game, which is configuration rather than anything running. An arena
/// server is a process that has chosen to serve one, which is this struct. A
/// room is one simulation inside it, which is `Room` above, and it is the only
/// one of the three where ships can see each other.
pub(crate) struct ArenaServer {
    /// Rooms this process holds for its zone, created on demand and reclaimed
    /// when they empty, capped by the zone's `max_rooms`. See the fill ladder in
    /// docs/architecture/zones-and-arenas.md.
    ///
    /// Empty means this process has not been told which zone it is, and it is
    /// the state a fleet arena boots into. An instance that is serving one keeps
    /// its last room however empty, so it still *is* an instance of that zone
    /// and appears as one. Reach for `first`, `get` and the iterators: indexing
    /// this is only safe where a room was just assigned into it.
    pub(crate) rooms: Vec<Room>,
    pub(crate) cfg: config::ConfigWatcher,
    /// Rated events on their way to the meta-layer. One per process, shared
    /// with every room, and inert on a deployment without accounts.
    pub(crate) spools: spool::Spools,
    /// The zone this process is serving, empty when it is running the built-in
    /// room because no catalog reached it.
    pub(crate) zone_name: String,
    /// The catalog as a directory handed it over, and the version, so the
    /// highest offered wins and a disagreement is a log line rather than a vote.
    pub(crate) catalog: Option<fleet::WireCatalog>,
    /// Last measured tick cost, for the metrics that ride in `STATUS`.
    pub(crate) tick_us: u32,
    /// An operator pin. While set, policy stops applying: admin.md's verbs win
    /// over selection, and the pin is displayed with who set it and when.
    pub(crate) pinned: Option<(String, String, u64)>,
    /// Set by a `drain` command or by wanting a different zone. No new joins.
    pub(crate) draining: bool,
    /// Whether the line about reporting being off has been said. `aim_spool`
    /// runs on a slow clock forever, and a log that repeats a standing
    /// condition every few seconds is a log nobody reads.
    pub(crate) said_quiet: bool,
    /// Everything about this instance's place in a fleet: its id, the views the
    /// directories pushed, what it has announced. Empty and harmless when no
    /// directory was ever configured.
    pub(crate) fleet: select::Fleet,
    /// Certified bot ratings, or only the defined anchor before certification.
    /// Held here because every room needs the same seed and a room may open
    /// long after startup.
    pub(crate) ladder: HashMap<String, f64>,
}

/// A renewable fleet-wide claim that this connection is the account's one
/// active rated session. The meta-layer owns exclusion; the arena owns the
/// socket lifetime and therefore the renew and release calls.
pub(crate) struct RatedLease {
    pub(crate) base: String,
    pub(crate) pool_token: String,
    pub(crate) instance: String,
    /// What this instance serves, carried so the row says where a pilot is and
    /// not only that they are somewhere. The friends page reads it.
    pub(crate) zone: String,
    pub(crate) account: u64,
    pub(crate) session: String,
    pub(crate) spool: std::sync::Arc<std::sync::Mutex<spool::Spool<spool::Event>>>,
    pub(crate) touched: std::time::Instant,
}

/// A token-backed connection that is not occupying a rated seat still checks
/// whether its account remains welcome. It carries no exclusion and therefore
/// does not stop the same pilot flying elsewhere while watching here.
pub(crate) struct StandingCheck {
    pub(crate) base: String,
    pub(crate) pool_token: String,
    pub(crate) account: u64,
    pub(crate) touched: std::time::Instant,
}

impl StandingCheck {
    pub(crate) async fn renew(&mut self) -> Result<(), String> {
        self.touched = std::time::Instant::now();
        meta::account_standing(&self.base, &self.pool_token, self.account).await
    }
}

impl RatedLease {
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn claim(
        base: String,
        pool_token: String,
        instance: String,
        zone: String,
        account: u64,
        session: String,
        spool: std::sync::Arc<std::sync::Mutex<spool::Spool<spool::Event>>>,
    ) -> Result<Option<(RatedLease, Vec<token::ClassRating>)>, String> {
        // A reconnect can reach the door just before the old connection's
        // cleanup releases its row. Give that settlement a brief chance to
        // finish instead of turning a millisecond race into a denial. The row
        // is never stolen: another live session waits through the same grace
        // and is still refused.
        let mut waits = 0;
        let (claimed, ratings) = loop {
            let result =
                meta::claim_rated_session(&base, &pool_token, account, &session, &instance, &zone)
                    .await?;
            if result.0 || waits == 12 {
                break result;
            }
            waits += 1;
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        };
        Ok(claimed.then(|| {
            (
                RatedLease {
                    base,
                    pool_token,
                    instance,
                    zone,
                    account,
                    session,
                    spool,
                    touched: std::time::Instant::now(),
                },
                ratings,
            )
        }))
    }

    pub(crate) async fn renew(&mut self) -> Result<bool, String> {
        self.touched = std::time::Instant::now();
        meta::claim_rated_session(
            &self.base,
            &self.pool_token,
            self.account,
            &self.session,
            &self.instance,
            &self.zone,
        )
        .await
        .map(|(claimed, _)| claimed)
    }

    pub(crate) async fn release(self) {
        self.release_after_settlement().await;
    }

    pub(crate) async fn release_after_settlement(mut self) {
        let mut attempts = 0u32;
        loop {
            match spool::settle_account(&self.spool, &self.base, &self.pool_token, self.account)
                .await
            {
                Ok(()) => break,
                Err(e) => {
                    attempts += 1;
                    if attempts == 1 || attempts.is_multiple_of(12) {
                        println!(
                            "rated settlement still owed for account {}: {e}",
                            self.account
                        );
                    }
                }
            }
            // A failed settlement must not age out the exclusion and let a
            // second session load a stale record. Renew while the spool or
            // meta-layer recovers, then try the acknowledgment again.
            if matches!(self.renew().await, Ok(false)) {
                println!(
                    "rated settlement lost its lease for account {}",
                    self.account
                );
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }

        // Once settlement is acknowledged, retry only the idempotent delete.
        // Renewing after a lost delete reply could recreate a lease the first
        // request had already removed.
        loop {
            match meta::release_rated_session(
                &self.base,
                &self.pool_token,
                self.account,
                &self.session,
            )
            .await
            {
                Ok(()) => return,
                Err(e) => println!(
                    "rated session release failed for account {}: {e}",
                    self.account
                ),
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    }
}

impl ArenaServer {
    /// Every player in every room, which is what a status push reports.
    ///
    /// There is deliberately no "the arena" accessor. There was one, meaning
    /// room zero, and every caller that used it was wrong once a process held
    /// more than one room: rule 1 let an instance change zone under players in
    /// room two, a kick could not reach them, and their ratings were never
    /// saved. Anything asking about the process asks about all of its rooms.
    pub(crate) fn total_players(&self) -> usize {
        self.rooms.iter().map(|r| r.humans()).sum()
    }

    pub(crate) fn total_bots(&self) -> usize {
        self.rooms.iter().map(|r| r.bot_count()).sum()
    }

    pub(crate) fn total_spectators(&self) -> usize {
        self.rooms.iter().map(|r| r.human_spectators()).sum()
    }

    /// Where the next arrival goes, per the fill ladder. Rung one is the fullest
    /// room below its player cap, which is most of the work and needs no
    /// coordination. Rung two is a new room here, when every room is at the
    /// zone's fill target and we are below `max_rooms`: 79 KB and a shared map,
    /// which is why it comes before anything involving another process.
    ///
    /// Fullest counts people, as the cap and the target do. Counting bots would
    /// put every room at target from the moment the bot server found it, so a
    /// zone would open its second room for its second player.
    ///
    /// `None` means this instance is out of room, and the client should try the
    /// next address the directory gave it.
    /// Where an arrival that named a room goes.
    ///
    /// A request rather than an instruction. The room may have filled between
    /// the list being drawn and the key landing, or closed, or this may not be
    /// the process holding it any more; in every one of those the ladder
    /// answers instead and the welcome says where they actually are. A refusal
    /// would be the honest-looking answer and the wrong one: the player asked
    /// to play this game, and the room was how they said it.
    pub(crate) fn room_wanted(&mut self, want: u32, seat: &Seat) -> Option<usize> {
        let cap = self.max_players();
        if want != 0 {
            if let Some(i) = self.rooms.iter().position(|r| r.number == want) {
                if self.rooms[i].humans() < cap {
                    return Some(i);
                }
            }
        }
        // A duel is one fight against one person, so who is already waiting
        // decides where an arrival goes. Every other zone wants the fullest
        // room, because what it is filling is a crowd.
        if self.rooms.iter().any(|room| room.is_duel()) {
            let class = self.rating_class();
            let rating = self
                .token_rating(seat, &class)
                .map(|(rating, _)| rating)
                .unwrap_or(rating::UNRATED);
            return self.duel_room_for_join(rating);
        }
        self.room_for_join()
    }

    /// How far apart two ratings may be and still be called a match.
    ///
    /// About two of the five visible tiers. Wide, deliberately: on a zone this
    /// size the choice is usually between one waiting person and no waiting
    /// person, and a fight against somebody a tier off is a better evening
    /// than a fight against the AI. What the band is really for is the case
    /// worth refusing, which is a Legend and a newcomer meeting because they
    /// happened to press play in the same minute.
    const DUEL_PAIR_BAND: f64 = 300.0;

    /// Who to put an arriving duellist with.
    ///
    /// The nearest rating among the rooms holding one person and a free seat,
    /// as long as it is inside the band. Rooms still waiting for anybody are
    /// preferred over rooms where a bot has already taken the seat, because
    /// taking that seat back costs the pair in it their fight.
    ///
    /// There is no queue and no widening band. A player who finds nobody opens
    /// their own room and becomes the person the next arrival is matched
    /// against, which is the same rule read from the other side, and the wait
    /// is bounded by the bot the arena sends after `DUEL_HOLD_TICKS`.
    fn duel_room_for(&self, rating: f64) -> Option<usize> {
        let mut best: Option<(usize, bool, f64)> = None;
        for (index, room) in self.rooms.iter().enumerate() {
            if room.humans() != 1 || room.humans() >= self.max_players() {
                continue;
            }
            let Some(theirs) = room.lone_human_rating() else {
                continue;
            };
            let gap = (theirs - rating).abs();
            if gap > Self::DUEL_PAIR_BAND {
                continue;
            }
            let free = room.bot_count() == 0;
            let better =
                best.is_none_or(|(_, best_free, best_gap)| (free, -gap) > (best_free, -best_gap));
            if better {
                best = Some((index, free, gap));
            }
        }
        best.map(|(index, _, _)| index)
    }

    /// Where an arriving duellist goes: beside the nearest-rated person
    /// waiting, or into a room of their own to become that person.
    pub(crate) fn duel_room_for_join(&mut self, rating: f64) -> Option<usize> {
        if let Some(index) = self.duel_room_for(rating) {
            return Some(index);
        }
        if self.rooms.len() < self.max_rooms() {
            match self.open_room() {
                Ok(index) => return Some(index),
                Err(e) => println!("cannot open another room: {e}"),
            }
        }
        // Every room is taken and none of them is a match. A fight against
        // somebody far off is still a fight, and refusing at the door would be
        // the arena telling a player the zone is full when it is not.
        self.room_for_join()
    }

    pub(crate) fn room_for_join(&mut self) -> Option<usize> {
        let cap = self.max_players();
        let target = self.fill_target();

        // Rung 1: fullest below cap.
        let best = self
            .rooms
            .iter()
            .enumerate()
            .filter(|(_, r)| r.humans() < cap)
            .max_by_key(|(_, r)| r.humans())
            .map(|(i, _)| i);

        // Only grow when every room has reached the target. A room holding six of
        // twenty wants the next six players, not a sibling.
        let all_at_target = self.rooms.iter().all(|r| r.humans() >= target);
        if let Some(i) = best {
            if !all_at_target || self.rooms.len() >= self.max_rooms() {
                return Some(i);
            }
        }

        // Rung 2: a new room here.
        if self.rooms.len() < self.max_rooms() {
            match self.open_room() {
                Ok(i) => return Some(i),
                Err(e) => {
                    println!("cannot open another room: {e}");
                    return best;
                }
            }
        }
        best
    }

    /// Where an arriving bot goes: the room shortest of the ones it wants, and
    /// nowhere at all when every room has what it asked for.
    ///
    /// A separate question from `room_for_join`, and it has to be. Rooms open
    /// because people arrive, so a bot must never grow one; and "fullest room"
    /// is the wrong answer for a bot, since it would stack every bot into room
    /// one and leave a room opened for players with nobody in it to fight.
    pub(crate) fn room_for_bot(&self) -> Option<usize> {
        if self.draining {
            return None;
        }
        self.rooms
            .iter()
            .enumerate()
            .map(|(i, r)| (i, self.bots_requested_by(i).saturating_sub(r.bot_count())))
            .filter(|(_, short)| *short > 0)
            .max_by_key(|(_, short)| *short)
            .map(|(i, _)| i)
    }

    /// Honor a room named by the bot director. Zero keeps the old behavior for
    /// ordinary zones whose directors only understand an instance-wide count.
    /// A duel zone requires an exact room, because which room a bot lands in
    /// decides who it is fighting.
    pub(crate) fn room_for_bot_request(&self, room: u32, seat: &Seat) -> Option<usize> {
        let _ = seat;
        if room == 0 {
            if self.rooms.iter().any(|candidate| candidate.is_duel()) {
                return None;
            }
            return self.room_for_bot();
        }
        if self.draining {
            return None;
        }
        let (index, found) = self
            .rooms
            .iter()
            .enumerate()
            .find(|(_, candidate)| candidate.number == room)?;
        (self.bots_requested_by(index) > found.bot_count()).then_some(index)
    }

    /// Whether this room is the one that keeps a duel going for anybody
    /// reading the menu: the zone's first, which `reclaim_rooms` keeps and a
    /// browsing client watches, and only while nobody is playing in it.
    ///
    /// Only the first, because a room is given back when it empties and one
    /// with bots flying in it never empties. One duel is also all this buys:
    /// the menu shows the room it would deploy you into.
    fn wants_stand_in(&self, index: usize) -> bool {
        index == 0
            && self
                .rooms
                .first()
                .is_some_and(|room| room.is_duel() && room.humans() == 0)
    }

    /// How long a lone pilot holds the other seat open for a person before the
    /// arena sends a bot to it.
    ///
    /// Ten seconds. Long enough that two people pressing play within a breath
    /// of each other meet, short enough that somebody alone on the zone is not
    /// left looking at an empty room wondering whether it is broken. The wait
    /// is visible: the clock reads dashes and the mode says it is waiting.
    ///
    /// It is not the only chance at a person. A human arriving later takes the
    /// seat from the bot, which is what `Room::join` already does when a room
    /// is full of AI and somebody is at the door.
    pub(crate) const DUEL_HOLD_TICKS: u32 = 10 * modes::TICKS_PER_SECOND;

    /// Whether this duel room has waited out its hold and should be given a
    /// bot. A room whose seat has only just emptied keeps holding.
    fn duel_hold_elapsed(&self, index: usize) -> bool {
        let Some(room) = self.rooms.get(index) else {
            return false;
        };
        room.duel_alone_ticks() >= Self::DUEL_HOLD_TICKS
    }

    fn bots_requested_by(&self, index: usize) -> usize {
        let Some(room) = self.rooms.get(index) else {
            return 0;
        };
        if !room.is_duel() {
            return room.bots_wanted();
        }
        // A duel is two ships. Two people in it want no bot at all; one person
        // wants one, but not before the seat has been held open for a person
        // first; and a room with nobody in it gets the pair that keep the zone
        // playing for whoever is reading the menu.
        if room.humans() >= 2 {
            0
        } else if room.humans() == 1 {
            usize::from(self.duel_hold_elapsed(index))
        } else if self.wants_stand_in(index) {
            2
        } else {
            0
        }
    }

    fn bot_requests(&self) -> Vec<fleet::BotRequest> {
        if self.draining {
            return Vec::new();
        }
        self.rooms
            .iter()
            .enumerate()
            .flat_map(|(index, room)| {
                let count = self.bots_requested_by(index);
                if count == 0 {
                    return Vec::new();
                }
                if !room.is_duel() {
                    return vec![fleet::BotRequest {
                        room: room.number,
                        count: count as u32,
                        target_slot: None,
                    }];
                }
                // An opponent for the person waiting, named by strength: the
                // authored archetype whose rating sits closest to theirs. The
                // director sends a replica of that pilot, and a near miss is a
                // slightly uneven fight rather than a wrong answer.
                //
                // The pair that keep an empty room playing name nobody. They
                // are a demonstration rather than a match, and drawing them
                // from the whole roster keeps the menu from showing the same
                // two pilots every time somebody looks.
                let target_slot = room.lone_human_rating().map(archetype_nearest_rating);
                let mut asked = vec![fleet::BotRequest {
                    room: room.number,
                    count: 1,
                    target_slot: target_slot.map(|slot| slot as u32),
                }];
                if count > 1 {
                    asked.push(fleet::BotRequest {
                        room: room.number,
                        count: 1,
                        target_slot: None,
                    });
                }
                asked
            })
            .collect()
    }

    /// What this process would like the bot server to supply, across every room.
    /// Zero while draining, which is what lets a drain finish rather than being
    /// topped up for ever by the thing that is supposed to be leaving.
    pub(crate) fn bots_wanted(&self) -> usize {
        if self.draining {
            return 0;
        }
        (0..self.rooms.len())
            .map(|index| self.bots_requested_by(index))
            .sum()
    }

    /// Every room number the zone is using anywhere, as far as this process can
    /// tell: its own, and every other instance's as the directories last
    /// described them.
    ///
    /// The fleet view is the same one `select` decides which zone to serve
    /// from, so this asks nothing new of anybody. A directory that has gone
    /// quiet takes its instances' numbers out of view with it, which can let a
    /// number be handed out twice; `settle_room_numbers` is what repairs that.
    pub(crate) fn elsewhere_in_zone(&self, zone: &str) -> std::collections::HashSet<u32> {
        let mut taken = std::collections::HashSet::new();
        if zone.is_empty() {
            return taken;
        }
        for o in self.fleet.union().by_instance.values() {
            if o.instance != self.fleet.instance && o.zone == zone {
                for rm in &o.rooms {
                    taken.insert(rm.number);
                }
            }
        }
        taken
    }

    /// The lowest representable room number free of a set.
    pub(crate) fn lowest_free(taken: &std::collections::HashSet<u32>) -> Option<u32> {
        (1..=MAX_ROOM_NUMBER).find(|n| !taken.contains(n))
    }

    /// The lowest number no live room of this zone is using.
    ///
    /// Lowest rather than next, so the numbers stay dense: a zone that has run
    /// for a day and reclaimed rooms all through it should still be offering
    /// room two rather than room ninety. A number is only reused after the room
    /// holding it closed, and a room closes only when it empties, so every
    /// "meet me in room two" the old one earned had already gone stale.
    pub(crate) fn free_room_number(&self) -> Option<u32> {
        let mut taken = self.elsewhere_in_zone(&self.zone_name);
        taken.extend(self.rooms.iter().map(|r| r.number));
        Self::lowest_free(&taken)
    }

    /// Settle a number two processes chose at once.
    ///
    /// Two instances can open a room inside the same status window, neither
    /// having seen the other's yet, and both land on the same number. Nothing
    /// coordinates them and nothing should: the directory observes and reports,
    /// and the edges decide. So the tie is broken by a rule both sides can
    /// apply alone and agree on without speaking, which is the instance id they
    /// already have of each other: the lexicographically smaller id keeps the
    /// number and the other moves.
    ///
    /// It happens seconds into a room's life, before its number has reached
    /// anybody's mouth, and it is the only renumber this scheme permits.
    pub(crate) fn settle_room_numbers(&mut self) {
        if self.zone_name.is_empty() || self.rooms.is_empty() {
            return;
        }
        let me = self.fleet.instance.clone();
        let mut theirs: std::collections::HashSet<u32> = std::collections::HashSet::new();
        for o in self.fleet.union().by_instance.values() {
            // Only instances that outrank us. A number we share with a larger
            // id is one they will move off, and both of us moving is both of us
            // landing on the next free number together.
            if o.zone == self.zone_name && o.instance < me {
                for rm in &o.rooms {
                    theirs.insert(rm.number);
                }
            }
        }
        if theirs.is_empty() {
            return;
        }
        let mut mine: std::collections::HashSet<u32> =
            self.rooms.iter().map(|r| r.number).collect();
        for i in 0..self.rooms.len() {
            let was = self.rooms[i].number;
            if !theirs.contains(&was) {
                continue;
            }
            let mut taken = theirs.clone();
            taken.extend(mine.iter().copied());
            let Some(next) = Self::lowest_free(&taken) else {
                println!(
                    "room {was} of {:?} is also {:?}'s, but all {MAX_ROOM_NUMBER} room numbers are occupied; keeping it until a number frees",
                    self.zone_name, "an older instance"
                );
                continue;
            };
            mine.remove(&was);
            mine.insert(next);
            self.rooms[i].renumber(next);
            println!(
                "room {was} of {:?} is also {:?}'s; renumbered to {next}",
                self.zone_name, "an older instance"
            );
        }
    }

    /// Another simulation of the same zone, sharing the map bytes. Bounded by
    /// `max_rooms`, which bounds both memory and the blast radius of this process
    /// dying, since rooms in a process share its fate.
    pub(crate) fn open_room(&mut self) -> Result<usize, String> {
        let z = self.wire_zone().cloned().ok_or("no zone definition")?;
        let number = self.free_room_number().ok_or_else(|| {
            format!(
                "all {MAX_ROOM_NUMBER} room numbers for zone {:?} are occupied",
                z.name
            )
        })?;
        // On the map the first room already holds, rather than unpacking the
        // bytes again. Geometry is a megabyte and immutable, so a hundred rooms
        // share one copy; without this the ceiling would be a memory limit
        // instead of a blast-radius one. There is no first room before a zone
        // arrives, and then the bytes are the only source there is.
        let mut fresh = Self::build_room(&z, self.rooms.first())?;
        fresh.number = number;
        fresh.spool = self.spools.rated.clone();
        fresh.pilots = self.spools.pilots.clone();
        fresh.matches = self.spools.matches.clone();
        prime_ratings(&mut fresh.rating, &self.ladder);
        self.rooms.push(fresh);
        let n = self.rooms.len();
        println!(
            "opened room {} ({n} of {}) for zone {:?}",
            self.rooms[n - 1].number,
            self.max_rooms(),
            z.name
        );
        Ok(n - 1)
    }

    /// Who is at the door, and what this room is allowed to say about them.
    ///
    /// A token is checked against the catalog's key and nothing else, so this
    /// answers without a network call and keeps answering while the meta-layer
    /// is down. What a pilot gets for arriving without one is a seat: they fly
    /// as an unknown guest under the name they gave, and nothing durable is
    /// written for them.
    /// `session` is this connection's, minted before the first refusal so that
    /// a pilot who never gets in still has their door events tied together.
    pub(crate) fn identify(
        &self,
        presented: &str,
        fallback_name: &str,
        declared_bot: bool,
        session: &pilot::Session,
    ) -> Result<Seat, String> {
        let guest = |name: &str| Seat {
            name: name.to_string(),
            bot: declared_bot,
            // A declared bot with no account is somebody else's bot, which is
            // exactly what the third-party label means. Without an account it
            // anchors nothing and earns nothing, which is the whole difference
            // between a declaration and a credential.
            label: if declared_bot {
                token::Label::ThirdPartyBot.to_byte()
            } else {
                token::Label::Unknown.to_byte()
            },
            rid: name.to_string(),
            account: None,
            carried: None,
            entitlements: sim::World::base_entitlements(),
            pending_kit: None,
            kitted: false,
            said_at: 0,
            expires: None,
            session: session.clone(),
        };
        let key = self
            .catalog
            .as_ref()
            .map(|c| c.meta_key.as_str())
            .unwrap_or_default();
        if presented.is_empty() || key.is_empty() {
            return Ok(guest(fallback_name));
        }
        let Some(vk) = token::verifying_key_from_hex(key) else {
            // A catalog with an unreadable key is an operator error, and
            // refusing every pilot over it would take the zone down. Say it
            // once per join and let people fly as guests.
            println!("catalog holds a meta key that is not a key; pilots fly as guests");
            return Ok(guest(fallback_name));
        };
        let claims = match token::verify(&vk, presented, token::now_secs()) {
            Ok(c) => c,
            Err(token::Bad::Expired) => return Err("your session expired; log in again".into()),
            Err(token::Bad::Version) => {
                return Err("your client and this fleet disagree about token format".into())
            }
            Err(_) => return Err("that session token is not one of ours".into()),
        };
        // The declaration and the account have to agree. A bot account that
        // did not declare would be labeled honestly and still sit in a human
        // seat, and a human account that declared would take a bot's exemption
        // from the cap. Neither is a thing to allow quietly.
        if claims.kind.is_bot() != declared_bot {
            return Err(if declared_bot {
                "this account is not a bot account; register the bot first".into()
            } else {
                "a bot account has to declare itself a bot".into()
            });
        }
        // The baseline is a floor, including for a token minted just before a
        // release raises a universal entitlement. A pilot who owns nothing
        // flies a whole ship; reading an absent or older list as an account
        // that owns nothing would put them in a chassis until login refresh.
        let entitlements = account_entitlements(&claims.entitlements);
        Ok(Seat {
            name: claims.name.clone(),
            bot: declared_bot,
            label: claims.label().to_byte(),
            rid: account_rid(claims.account),
            account: Some(claims.account),
            carried: Some(claims.ratings),
            entitlements,
            pending_kit: None,
            kitted: false,
            said_at: 0,
            expires: Some(claims.expires),
            session: session.clone(),
        })
    }

    /// A returning pilot's record, into the room they are actually joining.
    ///
    /// The number and its game count move together, always. A rating restored
    /// without its count is a number with no confidence attached: the pilot
    /// reads as still placing, and the next death moves them by a newcomer's K,
    /// which is four times as far as their record says it should.
    ///
    /// The token seeds a pilot this room has never seen. It is not a checkpoint:
    /// a reconnect or a return from watching must keep the movement already
    /// recorded in the room instead of restoring an older token over it.
    pub(crate) fn restore_pilot(&mut self, room: usize, seat: &Seat) {
        let class = self.rating_class();
        let Some((saved, played)) = self.token_rating(seat, &class) else {
            return;
        };
        if let Some(a) = self.rooms.get_mut(room) {
            if !a.rating.score.contains_key(&seat.rid) {
                a.rating.score.insert(seat.rid.clone(), saved);
                a.rating.games.insert(seat.rid.clone(), played);
            }
        }
    }

    /// The rating a token carried for this zone's class, if it carried one.
    /// A pilot who has never played this class arrives unrated and places,
    /// which is what a first game in a new class is supposed to be.
    pub(crate) fn token_rating(&self, seat: &Seat, class: &str) -> Option<(f64, u32)> {
        let r = seat.carried.as_ref()?.iter().find(|r| r.class == class)?;
        Some((r.rating, r.games))
    }

    /// Tell the spool where to send, which cannot be known until a catalog
    /// has arrived: the meta-layer's address travels with it. Catalog and zone
    /// commits call this immediately. The slow maintenance clock calls it too,
    /// so an environment override is refreshed without another state change.
    pub(crate) fn aim_spool(&mut self) {
        // Unless this arena has been told not to file anything, in which case
        // the spool is simply never aimed. An unaimed spool writes nothing and
        // posts nothing, which is the whole of the off switch: see
        // `Spool::push` and `spool::drain_loop`, both of which check `armed`.
        //
        // Nothing else changes. Accounts still work, a pilot still arrives
        // carrying the rating they earned, the room still rates every
        // exchange, the scoreboard still shows it, and the meta-layer keeps
        // running. What stops is this process filing any of it, which is what
        // a fleet under test wants: a test session's kills are real enough to
        // move a real ladder, and that ladder is other people's.
        if !reporting_enabled() {
            if !self.said_quiet {
                self.said_quiet = true;
                let held = self.spools.rated.lock().map(|s| s.len()).unwrap_or(0);
                println!(
                    "spool: VW_REPORT is off, rated events are not filed{}",
                    if held > 0 {
                        format!(" ({held} carried over from before are held, not dropped)")
                    } else {
                        String::new()
                    }
                );
            }
            return;
        }
        // The catalog's address is the public one, because it is the one a
        // client dials. An arena on the same host as the meta-layer should not
        // go out through DNS, TLS and a proxy to reach a port beside it, so
        // VW_META overrides it the same way VW_ARENAS does for the bot server.
        let url = match std::env::var("VW_META") {
            Ok(v) if !v.is_empty() => v,
            _ => self
                .catalog
                .as_ref()
                .map(|c| c.meta_url.clone())
                .unwrap_or_default(),
        };
        let token = std::env::var("VW_TOKEN").unwrap_or_default();
        // An incomplete destination cannot deliver anything. A fresh spool is
        // already unarmed, while one explicitly aimed by a caller must not be
        // erased by a catalog that has not supplied the other half yet.
        if url.is_empty() || token.is_empty() {
            return;
        }
        let (zone, class, instance) = (
            self.zone_name.clone(),
            self.rating_class(),
            self.fleet.instance.clone(),
        );
        self.spools.aim(&url, &token, &zone, &class, &instance);
    }

    /// Whether this zone admits only pilots who have claimed their account.
    pub(crate) fn wants_claimed(&self) -> bool {
        self.wire_zone()
            .map(|z| z.admission == "claimed")
            .unwrap_or(false)
    }

    pub(crate) fn accepts_bot_seat(&self, seat: &Seat) -> bool {
        let duel = self
            .wire_zone()
            .map(|zone| zone.mode == "duel")
            .unwrap_or_else(|| self.cfg.current.arena.mode == "duel");
        !duel || seat.label == token::Label::HouseBot.to_byte()
    }

    /// The class this zone rates into. One number per kind of game, per
    /// docs/design/rating.md: a warzone and a duel measure different
    /// skills and one number for both is a number about nothing.
    /// The zone definition is the authority, not the local config file: a
    /// catalog-served arena takes its mode from the zone it was handed, and
    /// the file underneath it is whatever the image happened to ship.
    pub(crate) fn rating_class(&self) -> String {
        let m = self
            .wire_zone()
            .map(|z| z.mode.clone())
            .unwrap_or_else(|| self.cfg.current.arena.mode.clone());
        if m.is_empty() {
            meta::DEFAULT_CLASS.to_string()
        } else {
            m
        }
    }

    /// Where this arena claims rated seats. An authenticated account without
    /// these credentials cannot be admitted safely: treating a missing meta
    /// route as permission would recreate the multi-room allowance bypass.
    pub(crate) fn rated_lease_args(&self) -> Result<(String, String, String, String), String> {
        let base = match std::env::var("VW_META") {
            Ok(v) if !v.is_empty() => v,
            _ => self
                .catalog
                .as_ref()
                .map(|c| c.meta_url.clone())
                .unwrap_or_default(),
        };
        let pool_token = std::env::var("VW_TOKEN").unwrap_or_default();
        if base.is_empty() || pool_token.is_empty() {
            return Err("rated session service is not configured".into());
        }
        Ok((
            base,
            pool_token,
            self.fleet.instance.clone(),
            self.zone_name.clone(),
        ))
    }

    /// Give back rooms nobody is in, keeping the first. Watchers count as being
    /// in a room even though they do not count as players in the directory.
    pub(crate) fn reclaim_rooms(&mut self) {
        if self.rooms.len() <= 1 {
            return;
        }
        let before = self.rooms.len();
        let mut keep_first = true;
        self.rooms.retain(|r| {
            if keep_first {
                keep_first = false;
                return true;
            }
            !r.players.is_empty() || !r.watchers.is_empty()
        });
        if self.rooms.len() != before {
            println!("reclaimed {} empty room(s)", before - self.rooms.len());
        }
    }

    /// One room built from a zone definition. Shared by the first room and by
    /// every room grown after it, so they cannot differ. `on` is a room already
    /// running this zone, whose map the new one borrows instead of unpacking a
    /// second megabyte of identical tiles.
    pub(crate) fn build_room(z: &fleet::WireZone, on: Option<&Room>) -> Result<Room, String> {
        if z.mode == "duel" && !certified_pilot_fixture_allows(z) {
            return Err(
                "the live duel zone differs from its certified pilot fixture; refusing to serve it"
                    .into(),
            );
        }
        let (maps, names) = match on {
            Some(r) => (r.maps.clone(), r.map_names.clone()),
            None => {
                let maps = z
                    .maps_b64
                    .iter()
                    .map(|m| {
                        let bytes = fleet::unb64(m).ok_or("map is not base64")?;
                        sim::unpack_map(&bytes)
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                (maps, z.map_names.clone())
            }
        };
        let first = maps.first().ok_or("the zone names no maps")?;
        let world = sim::World::on_map(0x5eed, std::sync::Arc::clone(first));
        let def: catalog::ZoneDef =
            toml::from_str(&z.zone_toml).map_err(|e| format!("zone.toml: {e}"))?;
        let mut room = Room::with_world_bare(world);
        // A names list that does not line up with the tiles would caption the
        // wrong ground; an older directory sends none at all. Either way the
        // room goes uncaptioned rather than mislabeled.
        room.map_names = if names.len() == maps.len() {
            names
        } else {
            Vec::new()
        };
        room.maps = maps;
        for w in room.retune(&def.arena) {
            println!("zone {}: {w}", z.name);
        }
        if let Some(m) = def.max_ships {
            room.world.cfg.max_ships = m;
        }
        room.set_teams(&def);
        if z.mode == "warzone" {
            room.add_default_flags();
            room.world.state.flag_count = def.arena.flags.min(room.world.state.flag_count);
        }
        room.mode = modes::build(&z.mode, &room.mode_setup(&def.arena));
        room.bot_fill = def.bot_fill();
        room.lag_policy = def.arena.lag.clone();
        room.max_watchers = def.max_watchers.unwrap_or(DEFAULT_MAX_WATCHERS);
        Ok(room)
    }

    /// Take a catalog a directory offered. Highest version wins; a tie with
    /// different content is an author error rather than a race, so it is a log
    /// line naming both directories rather than a vote.
    ///
    /// Refused outright, whatever its version, when this build cannot read it.
    /// Mid-deploy the fleet runs two builds at once, and an arena that catches
    /// the outgoing directory's offer first would otherwise hold zone text its
    /// own parser refuses. Holding it is what hurts: the version rules would
    /// then defend the unreadable copy against the converged directory's
    /// re-offer under the same number, and the instance sits at "cannot serve"
    /// until somebody restarts it. Holding nothing instead means the next
    /// offer arrives against `have` of zero and is simply taken.
    pub(crate) fn take_catalog(&mut self, c: fleet::WireCatalog, from: &str) {
        if let Err(why) = catalog_readable(&c) {
            println!(
                "catalog: refusing v{} from {from}: {why}. The offer and this \
                 build disagree about the format, which is a deploy caught \
                 half landed; keeping what we hold rather than pinning text \
                 we cannot serve",
                c.version
            );
            return;
        }
        let have = self.catalog.as_ref().map(|c| c.version).unwrap_or(0);
        if c.version < have {
            println!(
                "catalog: {from} offered v{} and we hold v{have} from {:?}; keeping ours",
                c.version, self.fleet.catalog_from
            );
            return;
        }
        if c.version == have {
            let same = self
                .catalog
                .as_ref()
                .map(|old| serde_json::to_string(old).ok() == serde_json::to_string(&c).ok())
                .unwrap_or(false);
            if !same {
                println!(
                    "catalog: {from} and {:?} both call this v{have} with different \
                     content; keeping what we hold. This is an author error, not a race",
                    self.fleet.catalog_from
                );
            }
            return;
        }
        println!(
            "catalog: v{} from {from} ({} zones)",
            c.version,
            c.zones.len()
        );
        self.fleet.catalog_from = from.to_string();

        // A running room does not change zone because the catalog changed: it
        // takes new settings for the zone it already serves, and the rest at its
        // next drain. A catalog edit is not a reason to disconnect anybody.
        if !self.zone_name.is_empty() {
            if let Some(z) = c.zone(&self.zone_name).cloned() {
                let protects_certified_fixture = self.rooms.iter().any(|room| room.is_duel())
                    && !certified_pilot_fixture_allows(&z);
                if protects_certified_fixture {
                    println!(
                        "catalog: duel update does not match the certified pilot fixture; \
                         keeping the running map and tuning"
                    );
                } else {
                    // The rotation is taken here too, and it is the reason an
                    // operator can change what a zone plays without emptying it.
                    // Unpacked once for the whole process rather than per room,
                    // the way `build_room` shares one set of tiles between rooms
                    // serving the same zone.
                    //
                    // The match in progress finishes on the ground it started on:
                    // swapping the map under a live fight is a desync everybody
                    // sees, and the next whistle is seconds away.
                    let maps: Vec<std::sync::Arc<sim::sim_map>> = z
                        .maps_b64
                        .iter()
                        .filter_map(|m| fleet::unb64(m))
                        .filter_map(|b| sim::unpack_map(&b).ok())
                        .collect();
                    if !maps.is_empty() {
                        for r in self.rooms.iter_mut() {
                            let same = r.maps.len() == maps.len()
                                && r.maps
                                    .iter()
                                    .zip(maps.iter())
                                    .all(|(a, b)| std::sync::Arc::ptr_eq(a, b) || a.tile == b.tile);
                            if same {
                                continue;
                            }
                            println!("room {}: rotation is now {} map(s)", r.number, maps.len());
                            r.maps = maps.clone();
                            // Only when they line up: the tiles above skip
                            // anything unreadable, and a shifted list would
                            // caption the wrong ground, which is worse than no
                            // caption.
                            r.map_names = if z.map_names.len() == maps.len() {
                                z.map_names.clone()
                            } else {
                                Vec::new()
                            };
                            // Whatever the room is standing on stays under it, so
                            // the index only has to be somewhere the next whistle
                            // can step from.
                            if r.map_at >= r.maps.len() {
                                r.map_at = 0;
                            }
                        }
                    }
                    if let Ok(def) = toml::from_str::<catalog::ZoneDef>(&z.zone_toml) {
                        let name = self.zone_name.clone();
                        for r in self.rooms.iter_mut() {
                            for w in r.retune(&def.arena) {
                                println!("zone {name}: {w}");
                            }
                            if let Some(m) = def.max_ships {
                                r.world.cfg.max_ships = m;
                            }
                            r.max_watchers = def.max_watchers.unwrap_or(DEFAULT_MAX_WATCHERS);
                            r.lag_policy = def.arena.lag.clone();
                            r.broadcast_settings();
                        }
                    }
                }
            }
        }
        self.catalog = Some(c);
        // The catalog carries the meta-layer address. Waiting for the slow
        // maintenance tick here would leave a newly registered arena unable to
        // file anything during its first room.
        self.aim_spool();
        // Deliberately not serving anything here. `default_zone` is what an
        // arena falls back to when it can reach no directory at all; taking it
        // the moment a catalog arrives would have every instance in a fleet grab
        // the same zone and skip selection entirely, which is exactly what the
        // first end-to-end run did. The decision loop chooses, within a couple of
        // seconds, and it is the only thing that chooses.
    }

    /// Tell every directory what we are serving, now rather than on the next
    /// heartbeat. Called on commit, because a directory that learns seconds late
    /// is a directory whose view is stale exactly when another instance is
    /// deciding against it, which is how a redundant commit happens.
    pub(crate) fn push_status(&self) {
        let msg = fleet::frame(fleet::A2D_STATUS, &self.status());
        for tx in self.fleet.senders.values() {
            let _ = tx.send(msg.clone());
        }
    }

    /// Announce an intent to every directory, now rather than on the next
    /// heartbeat. The expiry travels with it, so a crash here releases the claim
    /// on a timer rather than holding a zone empty forever.
    pub(crate) fn announce(&self, zone: &str) {
        let msg = fleet::frame(
            fleet::A2D_INTENT,
            &fleet::Intent {
                zone: zone.to_string(),
                expires_ms: select::INTENT_TTL_MS,
            },
        );
        let mut sent = 0;
        for tx in self.fleet.senders.values() {
            if tx.send(msg.clone()).is_ok() {
                sent += 1;
            }
        }
        println!("selection: announced intent to serve {zone:?} to {sent} directory(s)");
    }

    /// Stop taking joins and send every bot home, which is what makes a drain
    /// finish. A draining instance publishes `bots_wanted` of zero as well, so
    /// the bot server does not put back what this just let go; the eviction is
    /// belt to that braces, and the fast half, since it does not wait for a
    /// browse.
    pub(crate) fn begin_drain(&mut self) -> usize {
        self.draining = true;
        let gone: usize = self.rooms.iter_mut().map(|r| r.evict_all_bots()).sum();
        if gone > 0 {
            for r in self.rooms.iter_mut() {
                r.broadcast_roster();
            }
        }
        gone
    }

    /// The process is about to go, so every seated pilot's departure gets
    /// written down first. Without this a deploy read as a fleet of joins
    /// that never ended: the converge recreates the container, the sockets
    /// die with it, and the leave that a closing socket files never runs
    /// because nothing is left to run it. The spool is an append to a local
    /// file, so the rows survive to the next boot and drain from there.
    pub(crate) fn file_departures(&mut self) {
        for r in self.rooms.iter_mut() {
            let ids: Vec<u64> = r.players.keys().copied().collect();
            for id in ids {
                r.leave(id, pilot::why::RESTART);
            }
        }
    }

    /// An operator verb from a directory. `unknown_verb` is what lets a
    /// directory be newer than an arena without either pretending.
    pub(crate) fn run_command(&mut self, c: &fleet::Command) -> (&'static str, String) {
        match c.verb.as_str() {
            "drain" => {
                let bots = self.begin_drain();
                (
                    "done",
                    format!(
                        "draining {} player(s), {bots} bot(s) sent home",
                        self.total_players()
                    ),
                )
            }
            "pin" => {
                if self
                    .catalog
                    .as_ref()
                    .and_then(|k| k.zone(&c.args))
                    .is_none()
                {
                    return ("refused", format!("no zone {:?} in the catalog", c.args));
                }
                self.pinned = Some((c.args.clone(), c.actor.clone(), fleet::now_ms()));
                let def = self.catalog.as_ref().and_then(|k| k.zone(&c.args)).cloned();
                if let Some(def) = def {
                    if self.total_players() == 0 {
                        if let Err(e) = self.serve_zone(&def) {
                            return ("refused", e);
                        }
                    } else {
                        self.begin_drain();
                        return ("done", "pinned; draining before the switch".into());
                    }
                }
                ("done", format!("pinned to {:?}", c.args))
            }
            "unpin" => {
                self.pinned = None;
                ("done", String::new())
            }
            "kick" => {
                // Every room, because an operator naming a player does not know
                // or care which room of this process holds them.
                let before = self.total_players();
                let mut hit = 0;
                for r in self.rooms.iter_mut() {
                    let ids: Vec<u64> = r
                        .players
                        .iter()
                        .filter(|(_, p)| p.name.eq_ignore_ascii_case(&c.args))
                        .map(|(id, _)| *id)
                        .collect();
                    for id in &ids {
                        if let Some(p) = r.players.get(id) {
                            let mut message = vec![S2C_DENIED, DENY_BANNED];
                            message.extend_from_slice(b"this account is banned");
                            let _ = p.tx.try_send(Message::Binary(message));
                        }
                        r.leave(*id, pilot::why::KICKED);
                    }
                    let watchers: Vec<u64> = r
                        .watchers
                        .iter()
                        .filter(|(_, w)| w.seat.name.eq_ignore_ascii_case(&c.args))
                        .map(|(id, _)| *id)
                        .collect();
                    for id in &watchers {
                        if let Some(w) = r.watchers.get(id) {
                            let mut message = vec![S2C_DENIED, DENY_BANNED];
                            message.extend_from_slice(b"this account is banned");
                            let _ = w.tx.try_send(Message::Binary(message));
                        }
                        r.leave_watcher(*id);
                    }
                    if !ids.is_empty() || !watchers.is_empty() {
                        hit += ids.len() + watchers.len();
                        r.broadcast_roster();
                    }
                }
                if hit == 0 {
                    ("refused", format!("nobody here called {:?}", c.args))
                } else {
                    ("done", format!("kicked {hit} of {before}"))
                }
            }
            "restart" => {
                println!(
                    "restart asked for by {:?}; exiting so the supervisor restarts us",
                    c.actor
                );
                self.file_departures();
                // The container platform owns restarts. Exiting is the whole
                // implementation, and it is the honest one.
                std::process::exit(0);
            }
            _ => ("unknown_verb", c.verb.clone()),
        }
    }

    pub(crate) fn wire_zone(&self) -> Option<&fleet::WireZone> {
        self.catalog.as_ref()?.zone(&self.zone_name)
    }

    pub(crate) fn fill_target(&self) -> usize {
        self.wire_zone()
            .map(|z| z.fill_target as usize)
            .unwrap_or(catalog::DEFAULT_FILL_TARGET)
    }

    pub(crate) fn max_rooms(&self) -> usize {
        self.wire_zone()
            .map(|z| z.max_rooms as usize)
            .unwrap_or(1)
            .max(1)
            .min(MAX_ROOM_NUMBER as usize)
    }

    pub(crate) fn max_players(&self) -> usize {
        self.wire_zone()
            .map(|z| z.max_players as usize)
            .unwrap_or(DEFAULT_MAX_PLAYERS)
    }

    /// Which room a watcher lands in: the fullest, because they came to see
    /// people. `None` when this instance holds no room, which is every instance
    /// waiting for a zone.
    pub(crate) fn room_to_watch(&self) -> Option<usize> {
        self.rooms
            .iter()
            .enumerate()
            .max_by_key(|(_, a)| (a.humans(), a.players.len()))
            .map(|(i, _)| i)
    }

    /// Bans come from the catalog when there is one, because they are
    /// deployment-wide, and from the local file only when there is not.
    pub(crate) fn is_banned(&self, name: &str) -> bool {
        match &self.catalog {
            Some(c) => c.is_banned(name),
            None => self.cfg.current.is_banned(name),
        }
    }

    /// Take a zone definition and rebuild the room around it: its map, its
    /// settings, its mode. The one path by which a process changes what game it
    /// is running, so the map failing is a refusal rather than a half-change.
    pub(crate) fn serve_zone(&mut self, z: &fleet::WireZone) -> Result<(), String> {
        let number = Self::lowest_free(&self.elsewhere_in_zone(&z.name)).ok_or_else(|| {
            format!(
                "all {MAX_ROOM_NUMBER} room numbers for zone {:?} are occupied",
                z.name
            )
        })?;
        // From the bytes, not from a sibling: this is a change of zone, so the
        // map the running rooms hold is the wrong map.
        let mut room = Self::build_room(z, None)?;
        // Against the zone we are about to serve, and against nothing of our
        // own: every room we are holding served the old game and is about to be
        // replaced by this one, so counting their numbers would reserve names
        // that are being given up in the same breath.
        room.number = number;
        room.spool = self.spools.rated.clone();
        room.pilots = self.spools.pilots.clone();
        room.matches = self.spools.matches.clone();
        prime_ratings(&mut room.rating, &self.ladder);
        // Tell the bots before the room they are in stops existing. Rule 1 means
        // no human is here to tell, but bots are: an instance with only bots in
        // it reads as empty and is free to change zone, and a bot whose room was
        // replaced underneath it would sit on a socket that had gone quiet until
        // its own timeout rather than reconnecting into the new game.
        for r in self.rooms.iter_mut() {
            r.evict_all_bots();
        }
        // A change of zone replaces every room: they all served the old game.
        self.rooms = vec![room];
        self.zone_name = z.name.clone();
        // Each spooled row captures its destination when it is written. Move
        // that destination in the same commit that changes the running zone.
        self.aim_spool();
        self.draining = false;
        println!(
            "serving zone {:?}: mode {}, {} ships, {} players, teams {}",
            z.name,
            z.mode,
            z.max_ships,
            z.max_players,
            if self.rooms[0].public_teams == 0 {
                "free-for-all".to_string()
            } else {
                self.rooms[0]
                    .teams
                    .values()
                    .filter(|t| t.public)
                    .map(|t| t.name.as_str())
                    .collect::<Vec<_>>()
                    .join("/")
            }
        );
        Ok(())
    }
}

/// Put an arena's ratings on the same footing as every other: the AI marked
/// so it moves slowly against humans, each bot seeded from the calibrated
/// prior, and the anchor pinned last so nothing can overwrite the fixed
/// point the rest of the ladder is measured against.
/// A call sign as the rest of the system may hold it.
///
/// The wire hands us arbitrary bytes, and a name travels further than anywhere
/// else a client can reach: into every other player's roster, into the kill
/// feed and so into the logs, into the ratings map and so onto disk, and into
/// the argument of an operator's kick. So it is printable ASCII, single-spaced,
/// and at most 24 characters -- which is also the roster wire format's cap, so
/// what is stored is what everyone sees. Control characters would otherwise
/// ride into the logs (a newline forges a log line), and a 64 MB name is a
/// memory bill somebody else pays.
pub(crate) fn sanitize_name(raw: &str) -> String {
    let mut out = String::with_capacity(24);
    let mut pending_space = false;
    for c in raw.chars() {
        if c == ' ' || c.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if !c.is_ascii_graphic() {
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(c);
        if out.len() >= 24 {
            break;
        }
    }
    if out.is_empty() {
        "pilot".into()
    } else {
        out
    }
}

/// Seed a room's ladder with what the offline tournament measured.
///
/// Mark the authored roster as bots and apply whatever certified seed exists.
/// Before certification the map contains only the defined anchor, so every
/// other individual arrives unrated and earns a live number.
pub(crate) fn prime_ratings(r: &mut rating::Rating, ladder: &HashMap<String, f64>) {
    for (name, _, _) in ai::CALIBRATED {
        r.mark_bot(name);
        if let Some(&v) = ladder.get(name) {
            r.score.insert(name.to_string(), v);
        }
    }
    r.set_anchor(ai::ANCHOR, ai::ANCHOR_RATING);
}

/// Compact release-time attestation. `null` means no powered roster has passed
/// against the content in this binary yet.
pub(crate) const PILOT_CALIBRATION: &str = include_str!("../../zone/pilot-calibration.json");
pub(crate) const PILOT_CALIBRATION_ATTEMPTS: &str =
    include_str!("../../zone/pilot-calibration-attempts.json");

fn certified_pilot_fixture_allows(zone: &fleet::WireZone) -> bool {
    certified_pilot_attestation()
        .is_none_or(|release| calibrate::runtime_pilot_fixture_matches(&release.fixture, zone))
}

/// Whether this build can read every zone the catalog carries: the zone text
/// parses and each map unpacks. This is the door check `take_catalog` runs
/// before any version bookkeeping, because the version rules are only safe
/// among catalogs the process could actually serve. What they must never
/// defend is bytes from the far side of a deploy.
fn catalog_readable(c: &fleet::WireCatalog) -> Result<(), String> {
    for z in &c.zones {
        toml::from_str::<catalog::ZoneDef>(&z.zone_toml)
            .map_err(|e| format!("zone {:?}: zone.toml: {e}", z.name))?;
        for m in &z.maps_b64 {
            let bytes =
                fleet::unb64(m).ok_or_else(|| format!("zone {:?}: map is not base64", z.name))?;
            sim::unpack_map(&bytes).map_err(|e| format!("zone {:?}: map: {e}", z.name))?;
        }
    }
    Ok(())
}

pub(crate) fn certified_pilot_attestation(
) -> Option<&'static calibrate::PilotCalibrationAttestation> {
    static RELEASE: OnceLock<Option<calibrate::PilotCalibrationAttestation>> = OnceLock::new();
    RELEASE
        .get_or_init(|| {
            let release = serde_json::from_str::<Option<calibrate::PilotCalibrationAttestation>>(
                PILOT_CALIBRATION,
            )
            .ok()
            .flatten()?;
            let verifying_key = std::env::var("VW_META_VERIFY")
                .ok()
                .and_then(|key| token::verifying_key_from_hex(&key))?;
            calibrate::verified_current_attestation(
                &release,
                &pilots::roster(),
                PILOT_CALIBRATION_ATTEMPTS,
                &verifying_key,
            )
            .ok()
            .filter(|verified| *verified)
            .map(|_| release)
        })
        .as_ref()
}

/// The public identity of the exact signed pilot artifact this process could
/// verify. A signature is enough because it covers the execution fingerprint
/// as well as every statistical and content input in the attestation.
pub(crate) fn certified_pilot_attestation_id() -> &'static str {
    certified_pilot_attestation()
        .map(|release| release.signature.as_str())
        .unwrap_or_default()
}

fn pilot_release_claim(build: &str, attestation: &str) -> String {
    if build.is_empty() || build == "unknown" || attestation.is_empty() {
        build.to_string()
    } else {
        format!("v1:{build}:{attestation}")
    }
}

/// What a house bot presents in the existing JOIN build field. Provisional
/// play stays build-only. Certified play binds that build to the precise
/// attestation this binary verified locally.
pub(crate) fn house_bot_release_claim() -> String {
    pilot_release_claim(crate::metrics::commit(), certified_pilot_attestation_id())
}

fn certified_pilot_ratings() -> &'static HashMap<String, f64> {
    static RATINGS: OnceLock<HashMap<String, f64>> = OnceLock::new();
    RATINGS.get_or_init(|| {
        certified_pilot_attestation()
            .map(|release| &release.certified_ladder)
            .into_iter()
            .flatten()
            .map(|entry| (entry.callsign.clone(), entry.elo))
            .collect()
    })
}

/// What a certified offline tournament measured for one authored individual.
///
/// The meta-layer seeds a house bot's account from this the first time it is
/// claimed, which is where the calibrated ladder now enters the fleet. It used
/// to enter by priming every room, and that stopped reaching accounted bots the
/// moment their rating started being filed under an account rather than a name:
/// a room primes what it knows, and it no longer knows them by name.
pub(crate) fn calibrated_rating_from(name: &str, ratings: &HashMap<String, f64>) -> Option<f64> {
    let authored = pilots::archetype_for_callsign(name)
        .and_then(|archetype| ai::CALIBRATED.get(archetype))
        .map(|(callsign, _, _)| *callsign)
        .or_else(|| {
            ai::CALIBRATED
                .iter()
                .find_map(|(callsign, _, _)| (*callsign == name).then_some(*callsign))
        })?;
    if authored == ai::ANCHOR {
        // The pinned reference personality. It is a definition rather than a
        // measurement, so it does not depend on a calibration run having
        // happened.
        return Some(ai::ANCHOR_RATING);
    }
    ratings.get(authored).copied()
}

pub fn calibrated_rating(name: &str) -> Option<f64> {
    calibrated_rating_from(name, certified_pilot_ratings())
}

/// What one authored archetype is rated, measured where a certified tournament
/// has measured it and provisional where it has not.
pub(crate) fn archetype_rating(archetype: usize) -> f64 {
    ai::CALIBRATED
        .get(archetype)
        .and_then(|(callsign, _, _)| calibrated_rating(callsign))
        .unwrap_or_else(|| ai::provisional_rating(archetype))
}

/// The authored archetype closest in strength to a given rating.
///
/// This is the whole of duel matchmaking against the AI: a person waiting for
/// an opponent gets the house pilot nearest their own number. The roster is
/// eight, so the answer is a scan, and ties go to the weaker pilot because an
/// opponent slightly under a pilot's level is a better first guess than one
/// slightly over it.
pub(crate) fn archetype_nearest_rating(rating: f64) -> usize {
    (0..pilots::AUTHORED_PILOT_COUNT)
        .min_by(|a, b| {
            let d = |n: &usize| (archetype_rating(*n) - rating).abs();
            d(a).total_cmp(&d(b))
                .then_with(|| archetype_rating(*a).total_cmp(&archetype_rating(*b)))
        })
        .unwrap_or(0)
}

/// Read a certified seed an operator placed beside the arena, falling back to
/// the checked-in anchor. The calibration command never writes this file for
/// an exploratory or failed run.
pub(crate) fn load_ladder(_dir: &str) -> HashMap<String, f64> {
    let mut ratings = certified_pilot_ratings().clone();
    ratings.insert(ai::ANCHOR.into(), ai::ANCHOR_RATING);
    ratings
}

impl ArenaServer {
    /// A process with no game in it yet.
    ///
    /// Nothing is simulated until something says which zone this is. A room
    /// built at boot from the local file is a game: it accepts a join that
    /// names no zone, and the bot server, which asks each arena directly what
    /// it wants rather than reading the catalog, fills it to `bot_fill`. Two
    /// spare instances on the live fleet spent a night that way, running a
    /// warzone nobody could see in any listing, at a quarter of a one-core box
    /// between them. Rooms exist because somebody is served by them, and until
    /// a zone arrives nobody is.
    ///
    /// A standalone arena is the exception and says so out loud: see
    /// `serve_local`.
    pub(crate) fn new(
        cfg: config::ConfigWatcher,
        spools: spool::Spools,
        ladder: HashMap<String, f64>,
    ) -> Self {
        ArenaServer {
            rooms: Vec::new(),
            cfg,
            spools,
            zone_name: String::new(),
            catalog: None,
            tick_us: 0,
            pinned: None,
            draining: false,
            said_quiet: false,
            fleet: select::Fleet::default(),
            ladder,
        }
    }

    /// The game a standalone arena is: the local `zone.toml` and nothing else.
    ///
    /// Called only when no directory is going to name a zone, which is a laptop
    /// or a test. There the file is the whole deployment, so a room from it is
    /// the point rather than a placeholder, and it stays unnamed because a
    /// client dialling this address chose the address, not a listing.
    pub(crate) fn serve_local(&mut self) {
        let mut room = Room::new_from(&self.cfg.current);
        room.spool = self.spools.rated.clone();
        room.pilots = self.spools.pilots.clone();
        room.matches = self.spools.matches.clone();
        prime_ratings(&mut room.rating, &self.ladder);
        self.rooms = vec![room];
    }

    /// Re-read the zone file and push the new numbers into every live room.
    /// Nobody is disconnected: an operator tuning a bounce factor should not
    /// cost the room its round.
    pub(crate) fn reload(&mut self) {
        if let Some(msg) = self.cfg.poll() {
            println!("{msg}");
            // Cloned so the arena can be borrowed mutably while reading it, and
            // applied to every room: they are all the same game.
            let block = self.cfg.current.arena.clone();
            for r in self.rooms.iter_mut() {
                for w in r.retune(&block) {
                    println!("zone: {w}");
                }
                r.lag_policy = block.lag.clone();
                r.settings_generation = next_nonzero(r.settings_generation);
                r.broadcast_settings();
            }
        }
    }

    /// What this arena server tells a directory, and anybody else who asks.
    /// This doubles as the verification answer: a directory dials the claimed
    /// address, asks for status, and requires a well-formed reply, so the shape
    /// here is what proves an address works.
    pub(crate) fn status_json(&self) -> String {
        serde_json::to_string(&self.status()).unwrap_or_default()
    }

    pub(crate) fn status(&self) -> fleet::Status {
        let zone = self.zone_name.clone();
        let target = self.fill_target();
        fleet::Status {
            zone,
            build: crate::metrics::commit().to_string(),
            pilot_attestation: certified_pilot_attestation_id().to_string(),
            players: self.total_players() as u32,
            spectators: self.total_spectators() as u32,
            bots: self.total_bots() as u32,
            bots_wanted: self.bots_wanted() as u32,
            bot_requests: Some(self.bot_requests()),
            rooms: self
                .rooms
                .iter()
                .map(|r| {
                    let m = r.mode.match_state();
                    fleet::RoomView {
                        number: r.number,
                        players: r.humans() as u32,
                        bots: r.bot_count() as u32,
                        // Humans, because the bot server stands one down when
                        // somebody arrives, so a room packed with AI is not
                        // shut.
                        full: r.humans() >= self.max_players(),
                        clock: m.as_ref().map(|m| m.seconds_left as u32).unwrap_or(0),
                        playing: m.is_some_and(|m| m.playing),
                        waiting: r.duel_state().is_some_and(|duel| duel.state.waiting),
                    }
                })
                .collect(),
            max_rooms: self.max_rooms() as u32,
            // This instance's own answer to "am I out of room", so the rule lives
            // in one place rather than being recomputed by every reader. Capped
            // means every room is at the target *and* there is no headroom to
            // open another, which is the fill ladder's second rung exhausted.
            capped: self.rooms.iter().all(|r| r.humans() >= target)
                && self.rooms.len() >= self.max_rooms(),
            // Said out loud, because a pinned instance is one policy has
            // stopped applying to, and that is invisible from every other
            // number here.
            pinned: self
                .pinned
                .as_ref()
                .map(|p| p.0.clone())
                .unwrap_or_default(),
            pinned_by: self
                .pinned
                .as_ref()
                .map(|p| p.1.clone())
                .unwrap_or_default(),
            pinned_at_ms: self.pinned.as_ref().map(|p| p.2).unwrap_or(0),
            metrics: fleet::Metrics {
                tick_us: self.tick_us,
                // The worst-off client in the process. A depth near `OUT_QUEUE`
                // is a connection that cannot keep up and is losing snapshots,
                // which is the one player-visible symptom an operator cannot see
                // from a player count.
                queue_depth: self
                    .rooms
                    .iter()
                    .flat_map(|r| r.players.values())
                    .map(|p| (OUT_QUEUE - p.tx.capacity()) as u32)
                    .max()
                    .unwrap_or(0),
                // The other three of server.md's five, which this struct
                // filled with `Default::default()` until now: an operator
                // was being shown three zeroes that meant "never measured"
                // and read as "nothing wrong".
                //
                // Bandwidth is what this process is queueing to clients,
                // divided by the seats it is queueing to. Seats rather than
                // humans, because a bot is sent the same snapshot as anybody
                // and the number is about what the host is carrying.
                snapshot_bytes: crate::metrics::SNAPSHOT_LAST.get().max(0) as u32,
                bw_per_player: {
                    // Over the seats a snapshot is filtered for, not over every
                    // seat in the room. Our own bots are sent the whole room on
                    // loopback by design, and averaging fifty-one of those in
                    // with one player answered a question nobody asked: it read
                    // 305 kB/s while a real client was pulling 17.
                    let seats = crate::metrics::SEATS_OUT.get().max(1) as u64;
                    let per_sec = crate::metrics::OUT_RATE
                        .per_sec(crate::metrics::SNAPSHOT_BYTES_OUT.get(), fleet::now_ms());
                    (per_sec / seats) as u32
                },
                // Objective, weapon, and spectator restrictions applied per
                // second. Queue drops have their own metric and are transport
                // backpressure rather than the gameplay policy this names.
                lag_actions: crate::metrics::LAG_RATE
                    .per_sec(crate::metrics::LAG_ACTIONS.get(), fleet::now_ms())
                    as u32,
            },
        }
    }

    /// The name a joining player is shown. The catalog's when this process is
    /// serving a catalog zone, because that is the game they picked; the local
    /// file's only when no directory was ever reached.
    ///
    /// The name and nothing else. A sentence about the game rode a second
    /// line of this for as long as a zone had one, and the client dropped it
    /// at both places it draws this: what a game is gets said on the games
    /// list, in the format the catalog states.
    pub(crate) fn zone_msg(&self) -> Vec<u8> {
        let mut m = vec![S2C_ZONE];
        let name = match self.wire_zone() {
            Some(z) => z.name.clone(),
            None => self.cfg.current.name.clone(),
        };
        m.extend_from_slice(name.as_bytes());
        m
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{account_entitlements, pilot_release_claim, ArenaServer, MAX_ROOM_NUMBER};

    #[test]
    fn a_token_cannot_lower_a_new_universal_entitlement() {
        let mut old = vec![0; crate::sim::SLOT_COUNT];
        old[crate::sim::slot_stat(crate::sim::UP_ENERGY) as usize] = 7;
        old[crate::sim::slot_stat(crate::sim::UP_RECHARGE) as usize] = 5;
        old[crate::sim::slot_stat(crate::sim::UP_SPEED) as usize] = 5;
        old[crate::sim::slot_stat(crate::sim::UP_THRUST) as usize] = 1;
        old[crate::sim::slot_stat(crate::sim::UP_ROTATION) as usize] = 1;

        let merged = account_entitlements(&old);
        for stat in 0..crate::sim::UP_COUNT {
            assert_eq!(
                merged[crate::sim::slot_stat(stat) as usize],
                crate::sim::UP_STEPS
            );
        }
    }

    #[test]
    fn room_numbers_fill_the_wire_range_then_reuse_a_gap() {
        let mut taken: HashSet<u32> = (1..MAX_ROOM_NUMBER).collect();
        assert_eq!(ArenaServer::lowest_free(&taken), Some(MAX_ROOM_NUMBER));

        taken.insert(MAX_ROOM_NUMBER);
        assert_eq!(ArenaServer::lowest_free(&taken), None);

        taken.remove(&137);
        taken.insert(MAX_ROOM_NUMBER + 1);
        assert_eq!(
            ArenaServer::lowest_free(&taken),
            Some(137),
            "an out-of-range observation cannot consume or become a room name"
        );
    }

    #[test]
    fn a_certified_pilot_claim_identifies_the_exact_signed_artifact() {
        assert_eq!(
            pilot_release_claim("abc123", "deadbeef"),
            "v1:abc123:deadbeef"
        );
        assert_eq!(pilot_release_claim("abc123", ""), "abc123");
        assert_eq!(
            pilot_release_claim("unknown", "deadbeef"),
            "unknown",
            "a signature cannot turn an unidentified build into a certified release"
        );
    }
}
