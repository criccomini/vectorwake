//! Match artifacts written by arenas and read by public result pages.

use deadpool_postgres::Client;

use crate::catalog::Catalog;
use crate::growth::Artifact;

type Reply = (u16, serde_json::Value);

fn field(body: &serde_json::Value, name: &str) -> String {
    body.get(name)
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string()
}

pub(super) async fn route(
    catalog: &Catalog,
    db: &Client,
    path: &str,
    body: &serde_json::Value,
) -> Option<Reply> {
    let reply = match path {
        "/v1/matches" => {
            if catalog.pool_for_token(&field(body, "pool_token")).is_none() {
                return Some((403, serde_json::json!({ "error": "unknown pool token" })));
            }
            let zone = field(body, "zone");
            let instance = field(body, "instance");
            let empty = Vec::new();
            let events = body
                .get("events")
                .and_then(serde_json::Value::as_array)
                .unwrap_or(&empty);
            let mut stored = 0_u64;
            let mut rejected = Vec::new();
            for (index, value) in events.iter().enumerate() {
                let artifact = match serde_json::from_value::<Artifact>(value.clone()) {
                    Ok(artifact)
                        if artifact.id > 0
                            && artifact.pilots.len() <= 255
                            && artifact.replay.segments.len() <= 10 =>
                    {
                        artifact
                    }
                    Ok(_) => {
                        rejected.push(serde_json::json!({
                            "index": index,
                            "error": "match is outside its public bounds"
                        }));
                        continue;
                    }
                    Err(error) => {
                        rejected.push(serde_json::json!({
                            "index": index,
                            "error": format!("cannot read match: {error}")
                        }));
                        continue;
                    }
                };
                let json = match serde_json::to_value(&artifact) {
                    Ok(json) => json,
                    Err(error) => {
                        rejected.push(serde_json::json!({
                            "index": index,
                            "error": format!("cannot store match: {error}")
                        }));
                        continue;
                    }
                };
                match db
                    .execute(
                        "insert into match_artifacts (id, zone, instance, artifact)
                         values ($1, $2, $3, $4) on conflict (id) do nothing",
                        &[&artifact.id, &zone, &instance, &json],
                    )
                    .await
                {
                    Ok(n) => stored += n,
                    Err(error) => {
                        return Some((
                            500,
                            serde_json::json!({ "error": format!("cannot store match: {error}") }),
                        ));
                    }
                }
            }
            (
                200,
                serde_json::json!({ "stored": stored, "rejected": rejected }),
            )
        }
        "/v1/match" | "/v1/replay" => {
            let Some(id) = body
                .get("id")
                .and_then(serde_json::Value::as_i64)
                .filter(|id| *id > 0)
            else {
                return Some((400, serde_json::json!({ "error": "which match" })));
            };
            let row = match db
                .query_opt(
                    "select zone, instance, at::text, artifact
                       from match_artifacts where id = $1",
                    &[&id],
                )
                .await
            {
                Ok(Some(row)) => row,
                Ok(None) => {
                    return Some((404, serde_json::json!({ "error": "no such match" })));
                }
                Err(error) => {
                    return Some((
                        500,
                        serde_json::json!({ "error": format!("cannot read match: {error}") }),
                    ));
                }
            };
            let mut artifact = row.get::<_, serde_json::Value>(3);
            if path == "/v1/match" {
                artifact
                    .as_object_mut()
                    .map(|object| object.remove("replay"));
            }
            (
                200,
                serde_json::json!({
                    "zone": row.get::<_, String>(0),
                    "instance": row.get::<_, String>(1),
                    "at": row.get::<_, String>(2),
                    "match": artifact,
                }),
            )
        }
        _ => return None,
    };
    Some(reply)
}
