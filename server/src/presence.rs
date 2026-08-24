use std::sync::Arc;

use tokio::sync::mpsc;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum WatchMode {
    /// One pilot's eyes, live. Granted only for a ship on the watcher's own
    /// side, or to a holder of the `watch` capability, because same-side sight
    /// is information the side already has and staff sight is a grant the
    /// catalog wrote down. Everybody else gets the channel.
    Follow(u8),
    /// The room channel: the shared, delayed feed. The default, and the floor
    /// every unlawful ask falls to.
    Channel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SitOutWhy {
    Asked,
    Safe,
    Lag,
}

/// The one lifecycle state a connected pilot can occupy.
///
/// Combat state stays in the simulation. A dead pilot is still `Flying` here
/// because they still own a seat and will respawn in it. This state covers the
/// connection's membership in a room, which is the part that joins, spectating,
/// forced spectating, re-entry, and disconnects change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Presence {
    Unjoined,
    Flying { room: u32, member: u64 },
    Watching { room: u32, member: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PresenceEvent {
    JoinFlying {
        room: u32,
        member: u64,
    },
    JoinWatching {
        room: u32,
        member: u64,
    },
    SitOut {
        room: u32,
        member: u64,
        reason: SitOutWhy,
    },
    Resume {
        room: u32,
        member: u64,
    },
    Renumber {
        from: u32,
        to: u32,
        member: u64,
    },
    Disconnect {
        room: u32,
        member: u64,
    },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PresenceEffects {
    pub(crate) player_count_changed: bool,
    pub(crate) release_rated_lease: bool,
    pub(crate) connection_closed: bool,
}

impl Presence {
    pub(crate) fn flying(self) -> Option<(u32, u64)> {
        match self {
            Presence::Flying { room, member } => Some((room, member)),
            _ => None,
        }
    }

    pub(crate) fn watching(self) -> Option<(u32, u64)> {
        match self {
            Presence::Watching { room, member } => Some((room, member)),
            _ => None,
        }
    }

    pub(crate) fn transition(
        self,
        event: PresenceEvent,
    ) -> Result<(Presence, PresenceEffects), (Presence, PresenceEvent)> {
        use Presence::{Flying, Unjoined, Watching};
        use PresenceEvent::{Disconnect, JoinFlying, JoinWatching, Renumber, Resume, SitOut};

        let changed = PresenceEffects {
            player_count_changed: true,
            ..PresenceEffects::default()
        };
        let left_flight = PresenceEffects {
            player_count_changed: true,
            release_rated_lease: true,
            ..PresenceEffects::default()
        };
        let disconnected_flying = PresenceEffects {
            player_count_changed: true,
            release_rated_lease: true,
            connection_closed: true,
        };
        let disconnected_watching = PresenceEffects {
            player_count_changed: false,
            release_rated_lease: true,
            connection_closed: true,
        };
        let none = PresenceEffects::default();
        match (self, event) {
            (Unjoined, JoinFlying { room, member }) => Ok((Flying { room, member }, changed)),
            (Unjoined, JoinWatching { room, member }) => Ok((Watching { room, member }, none)),
            (
                Flying {
                    room: current,
                    member: current_member,
                },
                SitOut {
                    room,
                    member,
                    reason: _,
                },
            ) if current == room && current_member == member => {
                Ok((Watching { room, member }, left_flight))
            }
            (
                Watching {
                    room: current,
                    member: current_member,
                },
                Resume { room, member },
            ) if current == room && current_member == member => {
                Ok((Flying { room, member }, changed))
            }
            (
                Flying {
                    room: current,
                    member: current_member,
                },
                Renumber { from, to, member },
            ) if current == from && current_member == member => {
                Ok((Flying { room: to, member }, none))
            }
            (
                Watching {
                    room: current,
                    member: current_member,
                },
                Renumber { from, to, member },
            ) if current == from && current_member == member => {
                Ok((Watching { room: to, member }, none))
            }
            (
                Flying {
                    room: current,
                    member: current_member,
                },
                Disconnect { room, member },
            ) if current == room && current_member == member => Ok((Unjoined, disconnected_flying)),
            (
                Watching {
                    room: current,
                    member: current_member,
                },
                Disconnect { room, member },
            ) if current == room && current_member == member => {
                Ok((Unjoined, disconnected_watching))
            }
            _ => Err((self, event)),
        }
    }
}

#[derive(Clone)]
pub(crate) struct PresenceHandle {
    pub(crate) state: Arc<std::sync::Mutex<Presence>>,
    pub(crate) events: Option<mpsc::UnboundedSender<PresenceEffects>>,
}

impl PresenceHandle {
    /// A handle nobody is listening to, for a seat with no connection behind
    /// it. `connected` is the one every live session takes.
    #[cfg(test)]
    pub(crate) fn new() -> Self {
        Self {
            state: Arc::new(std::sync::Mutex::new(Presence::Unjoined)),
            events: None,
        }
    }

    pub(crate) fn connected() -> (Self, mpsc::UnboundedReceiver<PresenceEffects>) {
        let (events, receiver) = mpsc::unbounded_channel();
        (
            Self {
                state: Arc::new(std::sync::Mutex::new(Presence::Unjoined)),
                events: Some(events),
            },
            receiver,
        )
    }

    pub(crate) fn current(&self) -> Presence {
        *self.state.lock().expect("presence lock")
    }

    pub(crate) fn transition(
        &self,
        event: PresenceEvent,
    ) -> Result<PresenceEffects, (Presence, PresenceEvent)> {
        let mut current = self.state.lock().expect("presence lock");
        let (next, effects) = current.transition(event)?;
        *current = next;
        if let Some(events) = self.events.as_ref() {
            let _ = events.send(effects);
        }
        Ok(effects)
    }
}
