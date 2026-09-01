//! Public ladder and pilot-profile reads.

use deadpool_postgres::Client;

use crate::catalog::Catalog;
use crate::rating;
use crate::token::Kind;

use super::{kind_of, Throttle, KIND_HUMAN};

type Reply = (u16, serde_json::Value);

/// Handle public pilot reads. Returning `None` leaves the request for another
/// meta domain.
pub(super) async fn route(
    throttle: &Throttle,
    catalog: &Catalog,
    db: &Client,
    path: &str,
    body: &serde_json::Value,
    ip: &str,
) -> Option<Reply> {
    let hour = std::time::Duration::from_secs(3600);
    if !matches!(path, "/v1/pilots" | "/v1/pilot") {
        return None;
    }
    if !throttle.allow(&format!("pilots:{ip}"), 600, hour) {
        return Some((
            429,
            serde_json::json!({ "error": "too many pilot lookups; wait a while" }),
        ));
    }

    let reply = match path {
        // The public ladder carries only game facts. Account standing,
        // credentials, moderation state, and last activity stay on the admin
        // routes. Banned accounts, guests, and bots are omitted rather than
        // marked. The filters live inside `visible` so ranks and field sizes
        // count claimed humans only, without gaps left by hidden pilots.
        "/v1/pilots" => {
            let query: String = body
                .get("q")
                .and_then(|value| value.as_str())
                .unwrap_or("")
                .trim()
                .chars()
                .take(40)
                .collect();
            let provisional = rating::PROVISIONAL_GAMES as i32;
            let limit = body
                .get("limit")
                .and_then(|value| value.as_i64())
                .unwrap_or(50)
                .clamp(1, 100);
            let offset = body
                .get("offset")
                .and_then(|value| value.as_i64())
                .unwrap_or(0)
                .max(0);
            let rows = db
                .query(
                    "with visible as (
                         select a.id, n.call_sign, a.kind
                         from accounts a join names n on n.account = a.id
                         where not a.banned and a.kind = $5
                           and exists (select 1 from credentials c
                                       where c.account = a.id
                                         and c.method = 'password')
                     ), ladder as (
                         select r.account, r.class,
                                rank() over (partition by r.class order by r.rating desc) as pos,
                                count(*) over (partition by r.class) as of_n
                         from ratings r join visible v on v.id = r.account
                         where r.games >= $2
                     ), best as (
                         select distinct on (r.account)
                                r.account, r.class, r.rating, r.games
                         from ratings r join visible v on v.id = r.account
                         order by r.account, r.games desc, r.rating desc, r.class
                     )
                     select v.id, v.call_sign, v.kind,
                            b.class, b.rating, b.games, l.pos, l.of_n,
                            coalesce(ps.kills, 0), coalesce(ps.deaths, 0),
                            coalesce(ps.assists, 0)
                     from visible v
                     left join best b on b.account = v.id
                     left join ladder l on l.account = v.id and l.class = b.class
                     left join pilot_stats ps on ps.account = v.id
                     where $1 = '' or strpos(lower(v.call_sign), lower($1)) > 0
                     order by l.pos nulls last, b.rating desc nulls last,
                              lower(v.call_sign), v.id
                     limit $3 offset $4",
                    &[&query, &provisional, &limit, &offset, &KIND_HUMAN],
                )
                .await;
            let total: i64 = match db
                .query_one(
                    "select count(*) from accounts a join names n on n.account = a.id
                     where not a.banned and a.kind = $2
                       and exists (select 1 from credentials c
                                   where c.account = a.id
                                     and c.method = 'password')
                       and ($1 = '' or strpos(lower(n.call_sign), lower($1)) > 0)",
                    &[&query, &KIND_HUMAN],
                )
                .await
            {
                Ok(row) => row.get(0),
                Err(error) => {
                    return Some((500, serde_json::json!({ "error": format!("{error}") })));
                }
            };
            match rows {
                Ok(rows) => (
                    200,
                    serde_json::json!({
                        "total": total,
                        "offset": offset,
                        "limit": limit,
                        "pilots": rows.iter().map(|row| {
                            let kind: i16 = row.get(2);
                            let score: Option<f64> = row.get(4);
                            let games: Option<i32> = row.get(5);
                            let tier = match (score, games) {
                                (Some(score), Some(games))
                                    if games as u32 >= rating::PROVISIONAL_GAMES =>
                                {
                                    Some(rating::tier(score))
                                }
                                _ => None,
                            };
                            let class = row.get::<_, Option<String>>(3);
                            serde_json::json!({
                                "account": row.get::<_, i64>(0),
                                "name": row.get::<_, String>(1),
                                "kind": match kind_of(kind) {
                                    Kind::Human => "human",
                                    Kind::HouseBot => "house bot",
                                    Kind::ThirdPartyBot => "third-party bot",
                                },
                                "zone": class.as_deref()
                                    .map(|c| catalog.zone_label(c).to_string()),
                                "class": class,
                                "rating": score,
                                "games": games,
                                "tier": tier,
                                "rank": row.get::<_, Option<i64>>(6),
                                "of": row.get::<_, Option<i64>>(7),
                                "kills": row.get::<_, i64>(8),
                                "deaths": row.get::<_, i64>(9),
                                "assists": row.get::<_, i64>(10),
                            })
                        }).collect::<Vec<_>>(),
                    }),
                ),
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }

        "/v1/pilot" => {
            let account = body
                .get("account")
                .and_then(|value| value.as_i64())
                .unwrap_or(0);
            let pilot = db
                .query_opt(
                    "select a.id, n.call_sign, a.kind,
                            coalesce(ps.kills, 0), coalesce(ps.deaths, 0),
                            coalesce(ps.assists, 0)
                     from accounts a join names n on n.account = a.id
                     left join pilot_stats ps on ps.account = a.id
                     where a.id = $1 and not a.banned",
                    &[&account],
                )
                .await;
            let pilot = match pilot {
                Ok(Some(row)) => row,
                Ok(None) => {
                    return Some((404, serde_json::json!({ "error": "no such pilot" })));
                }
                Err(error) => {
                    return Some((500, serde_json::json!({ "error": format!("{error}") })));
                }
            };
            let provisional = rating::PROVISIONAL_GAMES as i32;
            let ratings = db
                .query(
                    "with visible_ratings as (
                         select r.account, r.class, r.rating, r.games
                         from ratings r
                         join accounts a on a.id = r.account and not a.banned
                                                and a.kind = $3
                                                and exists (
                                                    select 1 from credentials c
                                                    where c.account = a.id
                                                      and c.method = 'password'
                                                )
                         join names n on n.account = a.id
                     ), ladder as (
                         select account, class,
                                rank() over (partition by class order by rating desc) as pos,
                                count(*) over (partition by class) as of_n
                         from visible_ratings where games >= $2
                     )
                     select r.class, r.rating, r.games, l.pos, l.of_n
                     from ratings r
                     left join ladder l on l.account = r.account and l.class = r.class
                     where r.account = $1
                     order by r.games desc, r.rating desc, r.class",
                    &[&account, &provisional, &KIND_HUMAN],
                )
                .await;
            match ratings {
                Ok(rows) => {
                    let kind: i16 = pilot.get(2);
                    (
                        200,
                        serde_json::json!({
                            "pilot": {
                                "account": pilot.get::<_, i64>(0),
                                "name": pilot.get::<_, String>(1),
                                "kind": match kind_of(kind) {
                                    Kind::Human => "human",
                                    Kind::HouseBot => "house bot",
                                    Kind::ThirdPartyBot => "third-party bot",
                                },
                                "kills": pilot.get::<_, i64>(3),
                                "deaths": pilot.get::<_, i64>(4),
                                "assists": pilot.get::<_, i64>(5),
                                "ratings": rows.iter().map(|row| {
                                    let score: f64 = row.get(1);
                                    let games: i32 = row.get(2);
                                    let class: String = row.get(0);
                                    serde_json::json!({
                                        "zone": catalog.zone_label(&class),
                                        "class": class,
                                        "rating": score,
                                        "games": games,
                                        "tier": if games as u32 >= rating::PROVISIONAL_GAMES {
                                            Some(rating::tier(score))
                                        } else {
                                            None
                                        },
                                        "rank": row.get::<_, Option<i64>>(3),
                                        "of": row.get::<_, Option<i64>>(4),
                                    })
                                }).collect::<Vec<_>>(),
                            }
                        }),
                    )
                }
                Err(error) => (500, serde_json::json!({ "error": format!("{error}") })),
            }
        }

        _ => unreachable!(),
    };

    Some(reply)
}
