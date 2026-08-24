use crate::catalog::sha256_hex;

use super::{client_debug_of, client_error_of, Meta};

pub(super) async fn route(
    meta: &Meta,
    path: &str,
    body: &serde_json::Value,
    ip: &str,
) -> Option<(u16, serde_json::Value)> {
    let (scope, message) = match path {
        "/v1/client-error" => ("client-error", "too many error reports; wait a while"),
        "/v1/client-debug" => ("client-debug", "too many debug reports; wait a while"),
        _ => return None,
    };
    let hour = std::time::Duration::from_secs(3600);
    if !meta.throttle.allow(&format!("{scope}:{ip}"), 30, hour)
        || !meta.throttle.allow(&format!("{scope}:all"), 2000, hour)
    {
        return Some((429, serde_json::json!({ "error": message })));
    }
    let db = match meta.db().await {
        Ok(db) => db,
        Err(error) => return Some((503, serde_json::json!({ "error": error }))),
    };

    Some(match path {
        "/v1/client-error" => {
            let report = match client_error_of(body) {
                Ok(report) => report,
                Err(error) => return Some((400, serde_json::json!({ "error": error }))),
            };
            let fingerprint = sha256_hex(
                format!(
                    "{}\n{}\n{}\n{}\n{}",
                    report.kind,
                    report.message,
                    report.stack,
                    report.build,
                    report.account.unwrap_or(0)
                )
                .as_bytes(),
            );
            let stored = db
                .execute(
                    "insert into client_errors
                       (fingerprint, kind, message, stack, build, origin, page, user_agent, account)
                     values ($1, $2, $3, $4, $5, $6, $7, $8,
                             (select id from accounts where id = $9))
                     on conflict (fingerprint) do update
                     set last_at = now(), occurrences = client_errors.occurrences + 1,
                         origin = excluded.origin, page = excluded.page,
                         user_agent = excluded.user_agent",
                    &[
                        &fingerprint,
                        &report.kind,
                        &report.message,
                        &report.stack,
                        &report.build,
                        &report.origin,
                        &report.page,
                        &report.user_agent,
                        &report.account,
                    ],
                )
                .await;
            match stored {
                Ok(_) => (200, serde_json::json!({ "ok": true })),
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }
        "/v1/client-debug" => {
            let report = match client_debug_of(body) {
                Ok(report) => report,
                Err(error) => return Some((400, serde_json::json!({ "error": error }))),
            };
            let stored = db
                .execute(
                    "insert into client_debug
                       (kind, build, account, zone, room, wire, client_tick,
                        snapshot_tick, snapshot_seq, correction_px,
                        predicted_x, predicted_y, reconciled_x,
                        reconciled_y, predicted_vx, predicted_vy,
                        reconciled_vx, reconciled_vy, local_debt_px,
                        local_debt_deg, clock_adjust, repel_before_ticks,
                        repel_before_speed, repel_after_ticks,
                        repel_after_speed, frame_ms, snapshot_gap_ms,
                        input_ack, input_mask, input_margin, input_lead,
                        input_holes, user_agent)
                     values ($1, $2, (select id from accounts where id = $3),
                             $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
                             $14, $15, $16, $17, $18, $19, $20, $21, $22,
                             $23, $24, $25, $26, $27, $28, $29, $30, $31,
                             $32, $33)",
                    &[
                        &report.kind,
                        &report.build,
                        &report.account,
                        &report.zone,
                        &report.room,
                        &report.wire,
                        &report.client_tick,
                        &report.snapshot_tick,
                        &report.snapshot_seq,
                        &report.correction_px,
                        &report.predicted_x,
                        &report.predicted_y,
                        &report.reconciled_x,
                        &report.reconciled_y,
                        &report.predicted_vx,
                        &report.predicted_vy,
                        &report.reconciled_vx,
                        &report.reconciled_vy,
                        &report.local_debt_px,
                        &report.local_debt_deg,
                        &report.clock_adjust,
                        &report.repel_before_ticks,
                        &report.repel_before_speed,
                        &report.repel_after_ticks,
                        &report.repel_after_speed,
                        &report.frame_ms,
                        &report.snapshot_gap_ms,
                        &report.input_ack,
                        &report.input_mask,
                        &report.input_margin,
                        &report.input_lead,
                        &report.input_holes,
                        &report.user_agent,
                    ],
                )
                .await;
            match stored {
                Ok(_) => (200, serde_json::json!({ "stored": true })),
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }
        _ => unreachable!(),
    })
}
