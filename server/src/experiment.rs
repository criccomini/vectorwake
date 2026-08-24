//! Statistical building blocks for deterministic bot experiments.
//!
//! A scenario seed is the experimental unit. Matches that exchange sides,
//! starts, or controller assignments under that seed belong to one paired
//! observation. Nothing in this module treats ticks, shots, or teammates as
//! independent evidence.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::error::Error;
use std::fmt;

use serde::{Deserialize, Serialize};

const ELO_PER_LOG_ODDS: f64 = 400.0 / std::f64::consts::LN_10;

#[derive(Clone, Debug, PartialEq)]
pub enum ExperimentError {
    Empty(&'static str),
    InvalidProbability {
        field: &'static str,
        value: f64,
    },
    InvalidNumber {
        field: &'static str,
        value: f64,
    },
    InvalidCount {
        field: &'static str,
        value: usize,
    },
    LengthMismatch {
        expected: usize,
        actual: usize,
    },
    DuplicateName(String),
    UnknownHypothesis(String),
    #[allow(
        dead_code,
        reason = "reported by the serializable report validator and its focused tests"
    )]
    UnknownSeedPool(String),
    OverlappingSeedPools(String, String),
    MissingAnchor(String),
    DisconnectedComparisonGraph(String),
    SingularFit,
}

impl fmt::Display for ExperimentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty(field) => write!(f, "{field} must not be empty"),
            Self::InvalidProbability { field, value } => {
                write!(f, "{field} must be a probability, got {value}")
            }
            Self::InvalidNumber { field, value } => {
                write!(f, "{field} has an invalid value: {value}")
            }
            Self::InvalidCount { field, value } => {
                write!(f, "{field} has an invalid count: {value}")
            }
            Self::LengthMismatch { expected, actual } => {
                write!(f, "expected {expected} measurements, got {actual}")
            }
            Self::DuplicateName(name) => write!(f, "duplicate name: {name}"),
            Self::UnknownHypothesis(name) => write!(f, "unknown hypothesis: {name}"),
            Self::UnknownSeedPool(name) => write!(f, "unknown seed pool: {name}"),
            Self::OverlappingSeedPools(a, b) => {
                write!(f, "seed pools {a:?} and {b:?} overlap")
            }
            Self::MissingAnchor(name) => write!(f, "anchor {name:?} never appears"),
            Self::DisconnectedComparisonGraph(name) => {
                write!(f, "competitor {name:?} is disconnected from the anchor")
            }
            Self::SingularFit => write!(f, "the comparison matrix is singular"),
        }
    }
}

impl Error for ExperimentError {}

fn probability(field: &'static str, value: f64) -> Result<(), ExperimentError> {
    if value.is_finite() && (0.0..=1.0).contains(&value) {
        Ok(())
    } else {
        Err(ExperimentError::InvalidProbability { field, value })
    }
}

fn open_probability(field: &'static str, value: f64) -> Result<(), ExperimentError> {
    if value.is_finite() && value > 0.0 && value < 1.0 {
        Ok(())
    } else {
        Err(ExperimentError::InvalidProbability { field, value })
    }
}

fn finite(field: &'static str, value: f64) -> Result<(), ExperimentError> {
    if value.is_finite() {
        Ok(())
    } else {
        Err(ExperimentError::InvalidNumber { field, value })
    }
}

/// Two side-swapped matches run under one scenario seed.
///
/// Both scores are from the subject controller's perspective after the caller
/// has undone the side swap. A win is `1`, a draw is `0.5`, and a loss is `0`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PairedScenarioObservation {
    pub seed: u64,
    pub map: String,
    pub economy: String,
    pub first_score: f64,
    pub mirrored_score: f64,
    pub first_margin: f64,
    pub mirrored_margin: f64,
}

impl PairedScenarioObservation {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        seed: u64,
        map: impl Into<String>,
        economy: impl Into<String>,
        first_score: f64,
        mirrored_score: f64,
        first_margin: f64,
        mirrored_margin: f64,
    ) -> Result<Self, ExperimentError> {
        let map = map.into();
        let economy = economy.into();
        if map.trim().is_empty() {
            return Err(ExperimentError::Empty("scenario map"));
        }
        if economy.trim().is_empty() {
            return Err(ExperimentError::Empty("scenario economy"));
        }
        probability("first_score", first_score)?;
        probability("mirrored_score", mirrored_score)?;
        finite("first_margin", first_margin)?;
        finite("mirrored_margin", mirrored_margin)?;
        Ok(Self {
            seed,
            map,
            economy,
            first_score,
            mirrored_score,
            first_margin,
            mirrored_margin,
        })
    }

    pub fn score(&self) -> f64 {
        (self.first_score + self.mirrored_score) / 2.0
    }

    #[allow(
        dead_code,
        reason = "public paired-observation summary used by focused experiment tools"
    )]
    pub fn margin(&self) -> f64 {
        (self.first_margin + self.mirrored_margin) / 2.0
    }
}

/// One vector of measurements inside a seed cluster.
///
/// Duplicate seeds are averaged before resampling. This makes the seed, not
/// the number of rows or measurements inside it, the unit of evidence.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SeededMeasurements {
    pub seed: u64,
    pub values: Vec<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct BootstrapConfig {
    pub confidence: f64,
    pub replicates: usize,
    pub rng_seed: u64,
}

impl Default for BootstrapConfig {
    fn default() -> Self {
        Self {
            confidence: 0.95,
            replicates: 10_000,
            rng_seed: 0x5eed_5eed_d211_1001,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SimultaneousEstimate {
    pub label: String,
    pub estimate: f64,
    pub standard_error: f64,
    pub low: f64,
    pub high: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SimultaneousBootstrapReport {
    pub confidence: f64,
    pub clusters: usize,
    pub replicates: usize,
    pub family_size: usize,
    pub critical_value: f64,
    pub estimates: Vec<SimultaneousEstimate>,
}

#[derive(Clone, Copy)]
struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn index(&mut self, upper: usize) -> usize {
        (((self.next() as u128) * (upper as u128)) >> 64) as usize
    }
}

fn quantile(sorted: &[f64], probability: f64) -> f64 {
    if sorted.len() == 1 {
        return sorted[0];
    }
    let at = probability * (sorted.len() - 1) as f64;
    let below = at.floor() as usize;
    let above = at.ceil() as usize;
    let share = at - below as f64;
    sorted[below] + (sorted[above] - sorted[below]) * share
}

fn column_means(rows: &[Vec<f64>], width: usize) -> Vec<f64> {
    let mut means = vec![0.0; width];
    for row in rows {
        for (mean, value) in means.iter_mut().zip(row) {
            *mean += value;
        }
    }
    let n = rows.len() as f64;
    for mean in &mut means {
        *mean /= n;
    }
    means
}

fn cluster_means(
    labels: &[String],
    rows: &[SeededMeasurements],
) -> Result<Vec<Vec<f64>>, ExperimentError> {
    if labels.is_empty() {
        return Err(ExperimentError::Empty("measurement labels"));
    }
    if rows.is_empty() {
        return Err(ExperimentError::Empty("seeded measurements"));
    }
    let mut seen_labels = HashSet::new();
    for label in labels {
        if label.trim().is_empty() {
            return Err(ExperimentError::Empty("measurement label"));
        }
        if !seen_labels.insert(label.as_str()) {
            return Err(ExperimentError::DuplicateName(label.clone()));
        }
    }
    let mut grouped: BTreeMap<u64, (Vec<f64>, usize)> = BTreeMap::new();
    for row in rows {
        if row.values.len() != labels.len() {
            return Err(ExperimentError::LengthMismatch {
                expected: labels.len(),
                actual: row.values.len(),
            });
        }
        for &value in &row.values {
            finite("measurement", value)?;
        }
        let (sums, count) = grouped
            .entry(row.seed)
            .or_insert_with(|| (vec![0.0; labels.len()], 0));
        for (sum, value) in sums.iter_mut().zip(&row.values) {
            *sum += value;
        }
        *count += 1;
    }
    Ok(grouped
        .into_values()
        .map(|(mut sums, count)| {
            for sum in &mut sums {
                *sum /= count as f64;
            }
            sums
        })
        .collect())
}

/// Deterministic max-statistic bootstrap intervals over whole seed clusters.
///
/// The family width is taken from `labels`, so adding or removing a contrast
/// changes the simultaneous critical value without changing a constant in the
/// implementation.
pub fn bootstrap_simultaneous_means(
    labels: &[String],
    rows: &[SeededMeasurements],
    config: BootstrapConfig,
) -> Result<SimultaneousBootstrapReport, ExperimentError> {
    open_probability("bootstrap confidence", config.confidence)?;
    if config.replicates < 2 {
        return Err(ExperimentError::InvalidCount {
            field: "bootstrap replicates",
            value: config.replicates,
        });
    }
    let clusters = cluster_means(labels, rows)?;
    let width = labels.len();
    let estimate = column_means(&clusters, width);
    let mut rng = SplitMix64::new(config.rng_seed);
    let mut draws = Vec::with_capacity(config.replicates);
    for _ in 0..config.replicates {
        let mut draw = vec![0.0; width];
        for _ in 0..clusters.len() {
            let sampled = &clusters[rng.index(clusters.len())];
            for (sum, value) in draw.iter_mut().zip(sampled) {
                *sum += value;
            }
        }
        for value in &mut draw {
            *value /= clusters.len() as f64;
        }
        draws.push(draw);
    }

    let bootstrap_mean = column_means(&draws, width);
    let mut standard_error = vec![0.0; width];
    for draw in &draws {
        for (index, value) in draw.iter().enumerate() {
            standard_error[index] += (value - bootstrap_mean[index]).powi(2);
        }
    }
    for value in &mut standard_error {
        *value = (*value / (draws.len() - 1) as f64).sqrt();
    }

    let mut maxima = Vec::with_capacity(draws.len());
    for draw in &draws {
        let mut largest = 0.0f64;
        for index in 0..width {
            let delta = (draw[index] - estimate[index]).abs();
            let standardized = if standard_error[index] > 0.0 {
                delta / standard_error[index]
            } else if delta <= f64::EPSILON {
                0.0
            } else {
                f64::INFINITY
            };
            largest = largest.max(standardized);
        }
        maxima.push(largest);
    }
    maxima.sort_by(f64::total_cmp);
    let critical_value = quantile(&maxima, config.confidence);
    let estimates = labels
        .iter()
        .enumerate()
        .map(|(index, label)| {
            let margin = critical_value * standard_error[index];
            SimultaneousEstimate {
                label: label.clone(),
                estimate: estimate[index],
                standard_error: standard_error[index],
                low: estimate[index] - margin,
                high: estimate[index] + margin,
            }
        })
        .collect();
    Ok(SimultaneousBootstrapReport {
        confidence: config.confidence,
        clusters: clusters.len(),
        replicates: config.replicates,
        family_size: width,
        critical_value,
        estimates,
    })
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ContrastPValue {
    pub hypothesis: String,
    pub raw_p: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HolmContrast {
    pub hypothesis: String,
    pub raw_p: f64,
    pub adjusted_p: f64,
    pub rejected: bool,
}

/// Holm's step-down family-wise correction, returned in input order.
pub fn holm_adjust(
    contrasts: &[ContrastPValue],
    alpha: f64,
) -> Result<Vec<HolmContrast>, ExperimentError> {
    open_probability("family alpha", alpha)?;
    if contrasts.is_empty() {
        return Err(ExperimentError::Empty("Holm contrasts"));
    }
    let mut ordered = Vec::with_capacity(contrasts.len());
    let mut hypotheses = HashSet::new();
    for (index, contrast) in contrasts.iter().enumerate() {
        if contrast.hypothesis.trim().is_empty() {
            return Err(ExperimentError::Empty("Holm hypothesis"));
        }
        if !hypotheses.insert(contrast.hypothesis.as_str()) {
            return Err(ExperimentError::DuplicateName(contrast.hypothesis.clone()));
        }
        probability("raw p-value", contrast.raw_p)?;
        ordered.push((index, contrast));
    }
    ordered.sort_by(|left, right| {
        left.1
            .raw_p
            .total_cmp(&right.1.raw_p)
            .then_with(|| left.0.cmp(&right.0))
    });

    let mut adjusted = vec![0.0; contrasts.len()];
    let mut running = 0.0f64;
    for (rank, (original, contrast)) in ordered.iter().enumerate() {
        let remaining = contrasts.len() - rank;
        running = running.max((contrast.raw_p * remaining as f64).min(1.0));
        adjusted[*original] = running;
    }
    Ok(contrasts
        .iter()
        .enumerate()
        .map(|(index, contrast)| HolmContrast {
            hypothesis: contrast.hypothesis.clone(),
            raw_p: contrast.raw_p,
            adjusted_p: adjusted[index],
            rejected: adjusted[index] <= alpha,
        })
        .collect())
}

fn normal_cdf(value: f64) -> f64 {
    if value == f64::NEG_INFINITY {
        return 0.0;
    }
    if value == f64::INFINITY {
        return 1.0;
    }
    let x = value.abs();
    let t = 1.0 / (1.0 + 0.231_641_9 * x);
    let polynomial = t
        * (0.319_381_530
            + t * (-0.356_563_782
                + t * (1.781_477_937 + t * (-1.821_255_978 + t * 1.330_274_429))));
    let density = (-0.5 * x * x).exp() / (2.0 * std::f64::consts::PI).sqrt();
    let upper = 1.0 - density * polynomial;
    if value >= 0.0 {
        upper
    } else {
        1.0 - upper
    }
}

/// Inverse standard normal CDF using Peter Acklam's rational approximation.
fn inverse_normal(probability: f64) -> f64 {
    const A: [f64; 6] = [
        -3.969_683_028_665_376e1,
        2.209_460_984_245_205e2,
        -2.759_285_104_469_687e2,
        1.383_577_518_672_69e2,
        -3.066_479_806_614_716e1,
        2.506_628_277_459_239,
    ];
    const B: [f64; 5] = [
        -5.447_609_879_822_406e1,
        1.615_858_368_580_409e2,
        -1.556_989_798_598_866e2,
        6.680_131_188_771_972e1,
        -1.328_068_155_288_572e1,
    ];
    const C: [f64; 6] = [
        -7.784_894_002_430_293e-3,
        -3.223_964_580_411_365e-1,
        -2.400_758_277_161_838,
        -2.549_732_539_343_734,
        4.374_664_141_464_968,
        2.938_163_982_698_783,
    ];
    const D: [f64; 4] = [
        7.784_695_709_041_462e-3,
        3.224_671_290_700_398e-1,
        2.445_134_137_142_996,
        3.754_408_661_907_416,
    ];
    const LOW: f64 = 0.024_25;
    const HIGH: f64 = 1.0 - LOW;

    if probability <= 0.0 {
        return f64::NEG_INFINITY;
    }
    if probability >= 1.0 {
        return f64::INFINITY;
    }
    if probability < LOW {
        let q = (-2.0 * probability.ln()).sqrt();
        return (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0);
    }
    if probability > HIGH {
        let q = (-2.0 * (1.0 - probability).ln()).sqrt();
        return -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0);
    }
    let q = probability - 0.5;
    let r = q * q;
    (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
        / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct MeanTest {
    pub observations: usize,
    pub estimate: f64,
    pub standard_error: f64,
    pub null: f64,
    pub z: f64,
    /// Probability for the one-sided alternative `mean > null`.
    pub greater_p: f64,
}

/// A normal paired-mean test over scenario-level values.
///
/// The caller must collapse every mirrored match and any rows sharing a seed
/// before calling this function. This function cannot infer the experiment's
/// clustering from a flat slice.
pub fn paired_mean_test(values: &[f64], null: f64) -> Result<MeanTest, ExperimentError> {
    finite("paired-mean null", null)?;
    if values.len() < 2 {
        return Err(ExperimentError::InvalidCount {
            field: "paired-mean observations",
            value: values.len(),
        });
    }
    for &value in values {
        finite("paired-mean value", value)?;
    }
    let estimate = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values
        .iter()
        .map(|value| (value - estimate).powi(2))
        .sum::<f64>()
        / (values.len() - 1) as f64;
    let standard_error = (variance / values.len() as f64).sqrt();
    let (z, greater_p) = if standard_error == 0.0 {
        match estimate.total_cmp(&null) {
            std::cmp::Ordering::Greater => (f64::INFINITY, 0.0),
            std::cmp::Ordering::Equal => (0.0, 0.5),
            std::cmp::Ordering::Less => (f64::NEG_INFINITY, 1.0),
        }
    } else {
        let z = (estimate - null) / standard_error;
        (z, 1.0 - normal_cdf(z))
    };
    Ok(MeanTest {
        observations: values.len(),
        estimate,
        standard_error,
        null,
        z,
        greater_p,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EquivalenceVerdict {
    Equivalent,
    BelowBand,
    AboveBand,
    Inconclusive,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TostResult {
    pub estimate: f64,
    pub standard_error: f64,
    pub lower_bound: f64,
    pub upper_bound: f64,
    pub alpha: f64,
    pub lower_test_p: f64,
    pub upper_test_p: f64,
    pub confidence: f64,
    pub confidence_low: f64,
    pub confidence_high: f64,
    pub verdict: EquivalenceVerdict,
}

fn degenerate_tail(estimate: f64, boundary: f64, greater: bool) -> f64 {
    match estimate.total_cmp(&boundary) {
        std::cmp::Ordering::Equal => 0.5,
        std::cmp::Ordering::Greater if greater => 0.0,
        std::cmp::Ordering::Less if !greater => 0.0,
        _ => 1.0,
    }
}

/// Two one-sided normal tests for equivalence inside `(lower, upper)`.
///
/// The confidence interval is the corresponding `1 - 2 * alpha` interval.
/// Callers should use a family-adjusted alpha for confirmatory test families.
pub fn tost_equivalence(
    estimate: f64,
    standard_error: f64,
    lower: f64,
    upper: f64,
    alpha: f64,
) -> Result<TostResult, ExperimentError> {
    finite("equivalence estimate", estimate)?;
    finite("equivalence standard error", standard_error)?;
    finite("equivalence lower bound", lower)?;
    finite("equivalence upper bound", upper)?;
    if standard_error < 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "equivalence standard error",
            value: standard_error,
        });
    }
    if lower >= upper {
        return Err(ExperimentError::InvalidNumber {
            field: "equivalence band width",
            value: upper - lower,
        });
    }
    if !alpha.is_finite() || alpha <= 0.0 || alpha >= 0.5 {
        return Err(ExperimentError::InvalidProbability {
            field: "TOST alpha",
            value: alpha,
        });
    }
    let (lower_test_p, upper_test_p) = if standard_error == 0.0 {
        (
            degenerate_tail(estimate, lower, true),
            degenerate_tail(estimate, upper, false),
        )
    } else {
        (
            1.0 - normal_cdf((estimate - lower) / standard_error),
            normal_cdf((estimate - upper) / standard_error),
        )
    };
    let critical = inverse_normal(1.0 - alpha);
    let confidence_low = estimate - critical * standard_error;
    let confidence_high = estimate + critical * standard_error;
    let verdict = if lower_test_p <= alpha && upper_test_p <= alpha {
        EquivalenceVerdict::Equivalent
    } else if confidence_high < lower {
        EquivalenceVerdict::BelowBand
    } else if confidence_low > upper {
        EquivalenceVerdict::AboveBand
    } else {
        EquivalenceVerdict::Inconclusive
    };
    Ok(TostResult {
        estimate,
        standard_error,
        lower_bound: lower,
        upper_bound: upper,
        alpha,
        lower_test_p,
        upper_test_p,
        confidence: 1.0 - 2.0 * alpha,
        confidence_low,
        confidence_high,
        verdict,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Sidedness {
    OneSided,
    TwoSided,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PowerPlanRequest {
    pub alpha: f64,
    pub power: f64,
    pub minimum_detectable_effect: f64,
    pub observed_paired_variance: f64,
    pub sidedness: Sidedness,
    pub family_hypotheses: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PowerPlan {
    pub required_pairs: usize,
    pub family_alpha: f64,
    pub per_contrast_alpha: f64,
    pub critical_value: f64,
    pub power_value: f64,
    pub request: PowerPlanRequest,
}

/// Normal-approximation power plan for a paired mean contrast.
///
/// The family allocation is Bonferroni-conservative because a Holm procedure
/// has no single per-contrast alpha before the p-values are ordered.
pub fn plan_paired_mean(request: PowerPlanRequest) -> Result<PowerPlan, ExperimentError> {
    open_probability("power-plan alpha", request.alpha)?;
    open_probability("power-plan power", request.power)?;
    if request.power <= 0.5 {
        return Err(ExperimentError::InvalidProbability {
            field: "power-plan power",
            value: request.power,
        });
    }
    finite(
        "minimum detectable effect",
        request.minimum_detectable_effect,
    )?;
    finite("observed paired variance", request.observed_paired_variance)?;
    if request.minimum_detectable_effect <= 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "minimum detectable effect",
            value: request.minimum_detectable_effect,
        });
    }
    if request.observed_paired_variance < 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "observed paired variance",
            value: request.observed_paired_variance,
        });
    }
    if request.family_hypotheses == 0 {
        return Err(ExperimentError::InvalidCount {
            field: "family hypotheses",
            value: 0,
        });
    }
    let per_contrast_alpha = request.alpha / request.family_hypotheses as f64;
    let tails = match request.sidedness {
        Sidedness::OneSided => 1.0,
        Sidedness::TwoSided => 2.0,
    };
    let critical_value = inverse_normal(1.0 - per_contrast_alpha / tails);
    let power_value = inverse_normal(request.power);
    if !critical_value.is_finite() || !power_value.is_finite() {
        return Err(ExperimentError::InvalidNumber {
            field: "power-plan critical value",
            value: critical_value,
        });
    }
    let raw = request.observed_paired_variance * (critical_value + power_value).powi(2)
        / request.minimum_detectable_effect.powi(2);
    let required_pairs = raw.ceil().max(1.0) as usize;
    Ok(PowerPlan {
        required_pairs,
        family_alpha: request.alpha,
        per_contrast_alpha,
        critical_value,
        power_value,
        request,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EquivalencePowerPlanRequest {
    pub alpha: f64,
    /// Probability that every independent confirmatory pool passes.
    pub joint_power: f64,
    pub half_width: f64,
    pub observed_paired_variance: f64,
    pub family_hypotheses: usize,
    pub independent_confirmatory_gates: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EquivalencePowerPlan {
    pub required_pairs: usize,
    pub family_alpha: f64,
    pub per_claim_alpha: f64,
    pub per_gate_power: f64,
    pub critical_value: f64,
    pub power_value: f64,
    pub request: EquivalencePowerPlanRequest,
}

/// Normal-approximation power for symmetric TOST equivalence at a true mean
/// of zero. Total beta is divided across every prespecified matchup and
/// confirmatory pool, giving the requested joint-power lower bound without an
/// independence assumption.
pub fn plan_paired_equivalence(
    request: EquivalencePowerPlanRequest,
) -> Result<EquivalencePowerPlan, ExperimentError> {
    open_probability("equivalence-plan alpha", request.alpha)?;
    open_probability("equivalence-plan joint power", request.joint_power)?;
    finite("equivalence half-width", request.half_width)?;
    finite(
        "equivalence observed paired variance",
        request.observed_paired_variance,
    )?;
    if request.joint_power <= 0.5 {
        return Err(ExperimentError::InvalidProbability {
            field: "equivalence-plan joint power",
            value: request.joint_power,
        });
    }
    if request.half_width <= 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "equivalence half-width",
            value: request.half_width,
        });
    }
    if request.observed_paired_variance < 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "equivalence observed paired variance",
            value: request.observed_paired_variance,
        });
    }
    if request.family_hypotheses == 0 {
        return Err(ExperimentError::InvalidCount {
            field: "equivalence family hypotheses",
            value: 0,
        });
    }
    if request.independent_confirmatory_gates == 0 {
        return Err(ExperimentError::InvalidCount {
            field: "equivalence confirmatory pools",
            value: 0,
        });
    }
    let per_claim_alpha = request.alpha / request.family_hypotheses as f64;
    let per_gate_power =
        1.0 - (1.0 - request.joint_power) / request.independent_confirmatory_gates as f64;
    let critical_value = inverse_normal(1.0 - per_claim_alpha);
    // At a true mean of zero, symmetric TOST passes when the standardized
    // sample mean stays between equal bounds. This quantile gives the central
    // probability requested for one pool.
    let power_value = inverse_normal((1.0 + per_gate_power) / 2.0);
    if !critical_value.is_finite() || !power_value.is_finite() {
        return Err(ExperimentError::InvalidNumber {
            field: "equivalence-plan critical value",
            value: critical_value,
        });
    }
    let raw = request.observed_paired_variance * (critical_value + power_value).powi(2)
        / request.half_width.powi(2);
    let required_pairs = raw.ceil().max(1.0) as usize;
    Ok(EquivalencePowerPlan {
        required_pairs,
        family_alpha: request.alpha,
        per_claim_alpha,
        per_gate_power,
        critical_value,
        power_value,
        request,
    })
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BradleyTerryComparison {
    pub a: String,
    pub b: String,
    /// Mean score for `a`, with a tie scored as one half.
    pub score_a: f64,
    /// Number of independent experimental units represented by this row.
    pub weight: f64,
}

impl BradleyTerryComparison {
    #[allow(
        dead_code,
        reason = "public constructor used by focused Bradley-Terry audits"
    )]
    pub fn from_counts(
        a: impl Into<String>,
        b: impl Into<String>,
        a_wins: u64,
        ties: u64,
        b_wins: u64,
    ) -> Result<Self, ExperimentError> {
        let total = a_wins + ties + b_wins;
        if total == 0 {
            return Err(ExperimentError::InvalidCount {
                field: "Bradley-Terry comparison games",
                value: 0,
            });
        }
        Ok(Self {
            a: a.into(),
            b: b.into(),
            score_a: (a_wins as f64 + 0.5 * ties as f64) / total as f64,
            weight: total as f64,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BradleyTerryConfig {
    pub anchor: String,
    pub anchor_elo: f64,
    pub confidence: f64,
    pub ridge: f64,
    pub tolerance: f64,
    pub max_iterations: usize,
}

impl Default for BradleyTerryConfig {
    fn default() -> Self {
        Self {
            anchor: "anchor".to_string(),
            anchor_elo: 1200.0,
            confidence: 0.95,
            ridge: 1e-6,
            tolerance: 1e-10,
            max_iterations: 100,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StrengthEstimate {
    pub competitor: String,
    pub log_strength: f64,
    pub elo: f64,
    pub standard_error_elo: f64,
    pub confidence: f64,
    pub elo_low: f64,
    pub elo_high: f64,
    pub anchored: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BradleyTerryFit {
    pub anchor: String,
    pub anchor_elo: f64,
    pub confidence: f64,
    pub comparisons: usize,
    pub iterations: usize,
    pub converged: bool,
    pub penalized_log_likelihood: f64,
    pub strengths: Vec<StrengthEstimate>,
    /// Aggregated scores used by the fit. Keeping these rows makes a ladder
    /// auditable without rerunning the tournament.
    pub matchup_matrix: Vec<BradleyTerryComparison>,
}

fn logistic(value: f64) -> f64 {
    if value >= 0.0 {
        1.0 / (1.0 + (-value).exp())
    } else {
        let exp = value.exp();
        exp / (1.0 + exp)
    }
}

fn solve_linear(mut matrix: Vec<Vec<f64>>, mut rhs: Vec<f64>) -> Result<Vec<f64>, ExperimentError> {
    let n = rhs.len();
    for column in 0..n {
        let pivot = (column..n)
            .max_by(|left, right| {
                matrix[*left][column]
                    .abs()
                    .total_cmp(&matrix[*right][column].abs())
            })
            .unwrap_or(column);
        if matrix[pivot][column].abs() < 1e-12 {
            return Err(ExperimentError::SingularFit);
        }
        matrix.swap(column, pivot);
        rhs.swap(column, pivot);
        let divisor = matrix[column][column];
        for value in &mut matrix[column][column..] {
            *value /= divisor;
        }
        rhs[column] /= divisor;
        for row in 0..n {
            if row == column {
                continue;
            }
            let factor = matrix[row][column];
            if factor == 0.0 {
                continue;
            }
            let pivot_row: Vec<f64> = matrix[column][column..].to_vec();
            for (value, pivot_value) in matrix[row][column..].iter_mut().zip(pivot_row) {
                *value -= factor * pivot_value;
            }
            rhs[row] -= factor * rhs[column];
        }
    }
    Ok(rhs)
}

fn inverse_matrix(matrix: &[Vec<f64>]) -> Result<Vec<Vec<f64>>, ExperimentError> {
    let n = matrix.len();
    let mut inverse = vec![vec![0.0; n]; n];
    for column in 0..n {
        let mut unit = vec![0.0; n];
        unit[column] = 1.0;
        let solution = solve_linear(matrix.to_vec(), unit)?;
        for (row, value) in solution.into_iter().enumerate() {
            inverse[row][column] = value;
        }
    }
    Ok(inverse)
}

fn fit_state(
    beta: &[f64],
    rows: &[(Option<usize>, Option<usize>, f64, f64)],
    ridge: f64,
) -> (f64, Vec<f64>, Vec<Vec<f64>>) {
    let mut log_likelihood = -0.5 * ridge * beta.iter().map(|value| value * value).sum::<f64>();
    let mut gradient: Vec<f64> = beta.iter().map(|value| -ridge * value).collect();
    let mut information = vec![vec![0.0; beta.len()]; beta.len()];
    for &(a, b, score_a, weight) in rows {
        let beta_a = a.map_or(0.0, |index| beta[index]);
        let beta_b = b.map_or(0.0, |index| beta[index]);
        let chance = logistic(beta_a - beta_b).clamp(1e-15, 1.0 - 1e-15);
        log_likelihood += weight * (score_a * chance.ln() + (1.0 - score_a) * (1.0 - chance).ln());
        let residual = weight * (score_a - chance);
        let curvature = weight * chance * (1.0 - chance);
        if let Some(index) = a {
            gradient[index] += residual;
            information[index][index] += curvature;
        }
        if let Some(index) = b {
            gradient[index] -= residual;
            information[index][index] += curvature;
        }
        if let (Some(a_index), Some(b_index)) = (a, b) {
            information[a_index][b_index] -= curvature;
            information[b_index][a_index] -= curvature;
        }
    }
    for (index, row) in information.iter_mut().enumerate() {
        row[index] += ridge;
    }
    (log_likelihood, gradient, information)
}

fn validate_comparison_graph(
    names: &[String],
    anchor: usize,
    comparisons: &[BradleyTerryComparison],
) -> Result<(), ExperimentError> {
    let index: HashMap<&str, usize> = names
        .iter()
        .enumerate()
        .map(|(at, name)| (name.as_str(), at))
        .collect();
    let mut edges = vec![Vec::new(); names.len()];
    for comparison in comparisons {
        if comparison.a.trim().is_empty() || comparison.b.trim().is_empty() {
            return Err(ExperimentError::Empty("Bradley-Terry competitor"));
        }
        let a = index[comparison.a.as_str()];
        let b = index[comparison.b.as_str()];
        edges[a].push(b);
        edges[b].push(a);
    }
    let mut seen = vec![false; names.len()];
    let mut queue = VecDeque::from([anchor]);
    seen[anchor] = true;
    while let Some(at) = queue.pop_front() {
        for &next in &edges[at] {
            if !seen[next] {
                seen[next] = true;
                queue.push_back(next);
            }
        }
    }
    if let Some((at, _)) = seen.iter().enumerate().find(|(_, reached)| !**reached) {
        return Err(ExperimentError::DisconnectedComparisonGraph(
            names[at].clone(),
        ));
    }
    Ok(())
}

/// Fit Bradley-Terry strengths and express them on an anchored Elo scale.
///
/// Ties enter as half a win through `score_a`. The fit retains standard errors
/// from the observed Fisher information, while the anchor remains exact.
pub fn fit_bradley_terry(
    comparisons: &[BradleyTerryComparison],
    config: &BradleyTerryConfig,
) -> Result<BradleyTerryFit, ExperimentError> {
    if comparisons.is_empty() {
        return Err(ExperimentError::Empty("Bradley-Terry comparisons"));
    }
    if config.anchor.trim().is_empty() {
        return Err(ExperimentError::Empty("Bradley-Terry anchor"));
    }
    finite("anchor Elo", config.anchor_elo)?;
    open_probability("Bradley-Terry confidence", config.confidence)?;
    finite("Bradley-Terry ridge", config.ridge)?;
    finite("Bradley-Terry tolerance", config.tolerance)?;
    if config.ridge < 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "Bradley-Terry ridge",
            value: config.ridge,
        });
    }
    if config.tolerance <= 0.0 {
        return Err(ExperimentError::InvalidNumber {
            field: "Bradley-Terry tolerance",
            value: config.tolerance,
        });
    }
    if config.max_iterations == 0 {
        return Err(ExperimentError::InvalidCount {
            field: "Bradley-Terry iterations",
            value: 0,
        });
    }

    let mut set = BTreeSet::new();
    for comparison in comparisons {
        if comparison.a == comparison.b {
            return Err(ExperimentError::DuplicateName(comparison.a.clone()));
        }
        probability("Bradley-Terry score", comparison.score_a)?;
        finite("Bradley-Terry weight", comparison.weight)?;
        if comparison.weight <= 0.0 {
            return Err(ExperimentError::InvalidNumber {
                field: "Bradley-Terry weight",
                value: comparison.weight,
            });
        }
        set.insert(comparison.a.clone());
        set.insert(comparison.b.clone());
    }
    let names: Vec<String> = set.into_iter().collect();
    let anchor = names
        .iter()
        .position(|name| name == &config.anchor)
        .ok_or_else(|| ExperimentError::MissingAnchor(config.anchor.clone()))?;
    validate_comparison_graph(&names, anchor, comparisons)?;

    let mut free_index = vec![None; names.len()];
    let mut free = 0usize;
    for (at, index) in free_index.iter_mut().enumerate() {
        if at != anchor {
            *index = Some(free);
            free += 1;
        }
    }
    let by_name: HashMap<&str, usize> = names
        .iter()
        .enumerate()
        .map(|(at, name)| (name.as_str(), at))
        .collect();
    let rows: Vec<(Option<usize>, Option<usize>, f64, f64)> = comparisons
        .iter()
        .map(|comparison| {
            (
                free_index[by_name[comparison.a.as_str()]],
                free_index[by_name[comparison.b.as_str()]],
                comparison.score_a,
                comparison.weight,
            )
        })
        .collect();

    let mut beta = vec![0.0; free];
    let mut iterations = 0usize;
    let mut converged = false;
    for iteration in 0..config.max_iterations {
        iterations = iteration + 1;
        let (old_likelihood, gradient, information) = fit_state(&beta, &rows, config.ridge);
        let direction = solve_linear(information, gradient)?;
        let mut step = 1.0f64;
        let mut candidate = beta.clone();
        let mut candidate_likelihood;
        loop {
            for ((value, old), delta) in candidate.iter_mut().zip(&beta).zip(&direction) {
                *value = old + step * delta;
            }
            candidate_likelihood = fit_state(&candidate, &rows, config.ridge).0;
            if candidate_likelihood >= old_likelihood || step <= 1e-8 {
                break;
            }
            step /= 2.0;
        }
        let largest = direction
            .iter()
            .map(|value| (step * value).abs())
            .fold(0.0, f64::max);
        beta = candidate;
        if largest <= config.tolerance {
            converged = true;
            break;
        }
    }

    let (penalized_log_likelihood, _, information) = fit_state(&beta, &rows, config.ridge);
    let covariance = inverse_matrix(&information)?;
    let critical = inverse_normal(0.5 + config.confidence / 2.0);
    let strengths = names
        .iter()
        .enumerate()
        .map(|(at, name)| {
            let (log_strength, standard_error_log, anchored) = match free_index[at] {
                Some(index) => (beta[index], covariance[index][index].max(0.0).sqrt(), false),
                None => (0.0, 0.0, true),
            };
            let elo = config.anchor_elo + log_strength * ELO_PER_LOG_ODDS;
            let standard_error_elo = standard_error_log * ELO_PER_LOG_ODDS;
            StrengthEstimate {
                competitor: name.clone(),
                log_strength,
                elo,
                standard_error_elo,
                confidence: config.confidence,
                elo_low: elo - critical * standard_error_elo,
                elo_high: elo + critical * standard_error_elo,
                anchored,
            }
        })
        .collect();
    Ok(BradleyTerryFit {
        anchor: config.anchor.clone(),
        anchor_elo: config.anchor_elo,
        confidence: config.confidence,
        comparisons: comparisons.len(),
        iterations,
        converged,
        penalized_log_likelihood,
        strengths,
        matchup_matrix: comparisons.to_vec(),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SeedPoolRole {
    Development,
    Validation,
    Holdout,
    Replication,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SeedPool {
    pub name: String,
    pub role: SeedPoolRole,
    pub namespace: u64,
    pub first_seed: u64,
    pub count: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum HypothesisKind {
    Superiority { minimum_effect: f64 },
    Equivalence { lower: f64, upper: f64 },
    Calibration { maximum_absolute_error: f64 },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HypothesisSpec {
    pub id: String,
    pub description: String,
    pub kind: HypothesisKind,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SamplePlan {
    pub hypothesis_id: String,
    pub paired_scenarios: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContentFingerprint {
    pub name: String,
    pub digest: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CalibrationManifest {
    pub schema_version: u32,
    pub controller_version: String,
    pub profile_versions: Vec<String>,
    pub maps: Vec<String>,
    pub economies: Vec<String>,
    pub controller_fingerprint: String,
    pub profile_fingerprints: Vec<ContentFingerprint>,
    pub map_fingerprints: Vec<ContentFingerprint>,
    pub economy_fingerprints: Vec<ContentFingerprint>,
    pub seed_pools: Vec<SeedPool>,
    pub hypotheses: Vec<HypothesisSpec>,
    pub alpha: f64,
    pub power: f64,
    pub samples: Vec<SamplePlan>,
}

fn validate_fingerprints(
    values: &[ContentFingerprint],
    field: &'static str,
) -> Result<(), ExperimentError> {
    if values.is_empty() {
        return Err(ExperimentError::Empty(field));
    }
    let mut seen = HashSet::new();
    for value in values {
        if value.name.trim().is_empty() || value.digest.trim().is_empty() {
            return Err(ExperimentError::Empty(field));
        }
        if !seen.insert(value.name.as_str()) {
            return Err(ExperimentError::DuplicateName(value.name.clone()));
        }
    }
    Ok(())
}

fn unique_nonempty(values: &[String], field: &'static str) -> Result<(), ExperimentError> {
    if values.is_empty() {
        return Err(ExperimentError::Empty(field));
    }
    let mut seen = HashSet::new();
    for value in values {
        if value.trim().is_empty() {
            return Err(ExperimentError::Empty(field));
        }
        if !seen.insert(value) {
            return Err(ExperimentError::DuplicateName(value.clone()));
        }
    }
    Ok(())
}

impl CalibrationManifest {
    pub fn validate(&self) -> Result<(), ExperimentError> {
        if self.schema_version == 0 {
            return Err(ExperimentError::InvalidCount {
                field: "manifest schema version",
                value: 0,
            });
        }
        if self.controller_version.trim().is_empty() {
            return Err(ExperimentError::Empty("controller version"));
        }
        if self.controller_fingerprint.trim().is_empty() {
            return Err(ExperimentError::Empty("controller fingerprint"));
        }
        unique_nonempty(&self.profile_versions, "profile versions")?;
        unique_nonempty(&self.maps, "maps")?;
        unique_nonempty(&self.economies, "economies")?;
        validate_fingerprints(&self.profile_fingerprints, "profile fingerprints")?;
        validate_fingerprints(&self.map_fingerprints, "map fingerprints")?;
        validate_fingerprints(&self.economy_fingerprints, "economy fingerprints")?;
        open_probability("manifest alpha", self.alpha)?;
        open_probability("manifest power", self.power)?;
        if self.power <= 0.5 {
            return Err(ExperimentError::InvalidProbability {
                field: "manifest power",
                value: self.power,
            });
        }
        if self.seed_pools.is_empty() {
            return Err(ExperimentError::Empty("seed pools"));
        }
        let mut pool_names = HashSet::new();
        for pool in &self.seed_pools {
            if pool.name.trim().is_empty() {
                return Err(ExperimentError::Empty("seed pool name"));
            }
            if !pool_names.insert(pool.name.as_str()) {
                return Err(ExperimentError::DuplicateName(pool.name.clone()));
            }
            if pool.count == 0 {
                return Err(ExperimentError::InvalidCount {
                    field: "seed pool count",
                    value: 0,
                });
            }
            if pool.first_seed.checked_add(pool.count as u64).is_none() {
                return Err(ExperimentError::InvalidCount {
                    field: "seed pool range",
                    value: pool.count,
                });
            }
        }
        for (index, left) in self.seed_pools.iter().enumerate() {
            let left_end = left.first_seed + left.count as u64;
            for right in &self.seed_pools[index + 1..] {
                if left.namespace != right.namespace {
                    continue;
                }
                let right_end = right.first_seed + right.count as u64;
                if left.first_seed < right_end && right.first_seed < left_end {
                    return Err(ExperimentError::OverlappingSeedPools(
                        left.name.clone(),
                        right.name.clone(),
                    ));
                }
            }
        }
        if self.hypotheses.is_empty() {
            return Err(ExperimentError::Empty("hypotheses"));
        }
        let mut hypothesis_ids = HashSet::new();
        for hypothesis in &self.hypotheses {
            if hypothesis.id.trim().is_empty() {
                return Err(ExperimentError::Empty("hypothesis id"));
            }
            if hypothesis.description.trim().is_empty() {
                return Err(ExperimentError::Empty("hypothesis description"));
            }
            if !hypothesis_ids.insert(hypothesis.id.as_str()) {
                return Err(ExperimentError::DuplicateName(hypothesis.id.clone()));
            }
            match hypothesis.kind {
                HypothesisKind::Superiority { minimum_effect } => {
                    finite("minimum superiority effect", minimum_effect)?;
                    if minimum_effect <= 0.0 {
                        return Err(ExperimentError::InvalidNumber {
                            field: "minimum superiority effect",
                            value: minimum_effect,
                        });
                    }
                }
                HypothesisKind::Equivalence { lower, upper } => {
                    finite("equivalence lower bound", lower)?;
                    finite("equivalence upper bound", upper)?;
                    if lower >= upper {
                        return Err(ExperimentError::InvalidNumber {
                            field: "equivalence band width",
                            value: upper - lower,
                        });
                    }
                }
                HypothesisKind::Calibration {
                    maximum_absolute_error,
                } => {
                    finite("maximum calibration error", maximum_absolute_error)?;
                    if maximum_absolute_error <= 0.0 {
                        return Err(ExperimentError::InvalidNumber {
                            field: "maximum calibration error",
                            value: maximum_absolute_error,
                        });
                    }
                }
            }
        }
        if self.samples.is_empty() {
            return Err(ExperimentError::Empty("sample plans"));
        }
        let mut planned = HashSet::new();
        for sample in &self.samples {
            if !hypothesis_ids.contains(sample.hypothesis_id.as_str()) {
                return Err(ExperimentError::UnknownHypothesis(
                    sample.hypothesis_id.clone(),
                ));
            }
            if !planned.insert(sample.hypothesis_id.as_str()) {
                return Err(ExperimentError::DuplicateName(sample.hypothesis_id.clone()));
            }
            if sample.paired_scenarios == 0 {
                return Err(ExperimentError::InvalidCount {
                    field: "planned paired scenarios",
                    value: 0,
                });
            }
        }
        if planned.len() != hypothesis_ids.len() {
            let missing = hypothesis_ids
                .difference(&planned)
                .next()
                .copied()
                .unwrap_or_default();
            return Err(ExperimentError::UnknownHypothesis(missing.to_string()));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EstimateWithUncertainty {
    pub estimate: f64,
    pub standard_error: f64,
    pub confidence: f64,
    pub low: f64,
    pub high: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HypothesisVerdict {
    Passed,
    Failed,
    Inconclusive,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HypothesisResult {
    pub hypothesis_id: String,
    pub paired_scenarios: usize,
    pub estimate: EstimateWithUncertainty,
    pub raw_p: Option<f64>,
    pub adjusted_p: Option<f64>,
    pub verdict: HypothesisVerdict,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CalibrationReport {
    pub manifest: CalibrationManifest,
    pub evaluated_seed_pools: Vec<String>,
    pub paired_observations: usize,
    pub estimates: Vec<HypothesisResult>,
    pub strengths: Option<BradleyTerryFit>,
}

impl CalibrationReport {
    #[allow(
        dead_code,
        reason = "public validator used when generic reports are loaded for audit"
    )]
    pub fn validate(&self) -> Result<(), ExperimentError> {
        self.manifest.validate()?;
        if self.evaluated_seed_pools.is_empty() {
            return Err(ExperimentError::Empty("evaluated seed pools"));
        }
        let known_pools: HashSet<&str> = self
            .manifest
            .seed_pools
            .iter()
            .map(|pool| pool.name.as_str())
            .collect();
        let mut evaluated = HashSet::new();
        for pool in &self.evaluated_seed_pools {
            if !known_pools.contains(pool.as_str()) {
                return Err(ExperimentError::UnknownSeedPool(pool.clone()));
            }
            if !evaluated.insert(pool.as_str()) {
                return Err(ExperimentError::DuplicateName(pool.clone()));
            }
        }
        if self.paired_observations == 0 {
            return Err(ExperimentError::InvalidCount {
                field: "reported paired observations",
                value: 0,
            });
        }
        let hypotheses: HashSet<&str> = self
            .manifest
            .hypotheses
            .iter()
            .map(|hypothesis| hypothesis.id.as_str())
            .collect();
        if self.estimates.is_empty() {
            return Err(ExperimentError::Empty("reported estimates"));
        }
        let mut reported = HashSet::new();
        for result in &self.estimates {
            if !hypotheses.contains(result.hypothesis_id.as_str()) {
                return Err(ExperimentError::UnknownHypothesis(
                    result.hypothesis_id.clone(),
                ));
            }
            if !reported.insert(result.hypothesis_id.as_str()) {
                return Err(ExperimentError::DuplicateName(result.hypothesis_id.clone()));
            }
            if result.paired_scenarios == 0 {
                return Err(ExperimentError::InvalidCount {
                    field: "reported hypothesis samples",
                    value: 0,
                });
            }
            finite("reported estimate", result.estimate.estimate)?;
            finite("reported standard error", result.estimate.standard_error)?;
            open_probability("reported confidence", result.estimate.confidence)?;
            finite("reported interval low", result.estimate.low)?;
            finite("reported interval high", result.estimate.high)?;
            if result.estimate.standard_error < 0.0 || result.estimate.low > result.estimate.high {
                return Err(ExperimentError::InvalidNumber {
                    field: "reported uncertainty",
                    value: result.estimate.standard_error,
                });
            }
            if let Some(raw) = result.raw_p {
                probability("reported raw p-value", raw)?;
            }
            if let Some(adjusted) = result.adjusted_p {
                probability("reported adjusted p-value", adjusted)?;
                if result.raw_p.is_some_and(|raw| adjusted < raw) {
                    return Err(ExperimentError::InvalidProbability {
                        field: "reported adjusted p-value",
                        value: adjusted,
                    });
                }
            }
        }
        if reported.len() != hypotheses.len() {
            let missing = hypotheses
                .difference(&reported)
                .next()
                .copied()
                .unwrap_or_default();
            return Err(ExperimentError::UnknownHypothesis(missing.to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(left: f64, right: f64, tolerance: f64) {
        assert!(
            (left - right).abs() <= tolerance,
            "{left} was not within {tolerance} of {right}"
        );
    }

    #[test]
    fn a_mirrored_pair_is_one_observation() {
        let observation = PairedScenarioObservation::new(7, "drydock", "30", 1.0, 0.5, 3.0, -1.0)
            .expect("a valid pair");
        assert_eq!(observation.score(), 0.75);
        assert_eq!(observation.margin(), 1.0);
        assert!(PairedScenarioObservation::new(7, "m", "e", 1.1, 0.5, 0.0, 0.0).is_err());
    }

    #[test]
    fn seed_bootstrap_clusters_duplicate_rows_and_repeats_exactly() {
        let labels = vec!["score".to_string()];
        let rows = vec![
            SeededMeasurements {
                seed: 1,
                values: vec![0.0],
            },
            SeededMeasurements {
                seed: 1,
                values: vec![2.0],
            },
            SeededMeasurements {
                seed: 2,
                values: vec![10.0],
            },
        ];
        let config = BootstrapConfig {
            confidence: 0.90,
            replicates: 2_000,
            rng_seed: 19,
        };
        let first = bootstrap_simultaneous_means(&labels, &rows, config).expect("a bootstrap");
        let second = bootstrap_simultaneous_means(&labels, &rows, config).expect("same bootstrap");
        assert_eq!(first, second);
        assert_eq!(first.clusters, 2);
        assert_eq!(first.estimates[0].estimate, 5.5);
        assert!(first.estimates[0].low < 5.5);
        assert!(first.estimates[0].high > 5.5);
    }

    #[test]
    fn simultaneous_bootstrap_grows_with_the_declared_family() {
        let rows: Vec<SeededMeasurements> = (0..40)
            .map(|seed| SeededMeasurements {
                seed,
                values: vec![
                    (seed % 7) as f64,
                    ((seed * 11 + 3) % 17) as f64,
                    ((seed * 5 + 1) % 13) as f64,
                ],
            })
            .collect();
        let config = BootstrapConfig {
            confidence: 0.95,
            replicates: 4_000,
            rng_seed: 41,
        };
        let one_rows: Vec<SeededMeasurements> = rows
            .iter()
            .map(|row| SeededMeasurements {
                seed: row.seed,
                values: vec![row.values[0]],
            })
            .collect();
        let one = bootstrap_simultaneous_means(&["a".to_string()], &one_rows, config)
            .expect("one estimate");
        let three = bootstrap_simultaneous_means(
            &["a".to_string(), "b".to_string(), "c".to_string()],
            &rows,
            config,
        )
        .expect("three estimates");
        assert_eq!(three.family_size, 3);
        assert!(three.critical_value >= one.critical_value);
    }

    #[test]
    fn holm_is_dynamic_and_preserves_input_order() {
        let contrasts = vec![
            ContrastPValue {
                hypothesis: "third".into(),
                raw_p: 0.04,
            },
            ContrastPValue {
                hypothesis: "first".into(),
                raw_p: 0.01,
            },
            ContrastPValue {
                hypothesis: "second".into(),
                raw_p: 0.03,
            },
        ];
        let adjusted = holm_adjust(&contrasts, 0.05).expect("Holm contrasts");
        assert_eq!(adjusted[0].hypothesis, "third");
        close(adjusted[0].adjusted_p, 0.06, 1e-12);
        close(adjusted[1].adjusted_p, 0.03, 1e-12);
        close(adjusted[2].adjusted_p, 0.06, 1e-12);
        assert!(!adjusted[0].rejected);
        assert!(adjusted[1].rejected);
        assert!(!adjusted[2].rejected);
    }

    #[test]
    fn tost_proves_equivalence_instead_of_accepting_a_null() {
        let tight = tost_equivalence(0.50, 0.01, 0.45, 0.55, 0.05).expect("a TOST");
        assert_eq!(tight.verdict, EquivalenceVerdict::Equivalent);
        close(tight.confidence, 0.90, 1e-12);
        assert!(tight.confidence_low > 0.45 && tight.confidence_high < 0.55);

        let noisy = tost_equivalence(0.50, 0.04, 0.45, 0.55, 0.05).expect("a noisy TOST");
        assert_eq!(noisy.verdict, EquivalenceVerdict::Inconclusive);

        let strong = tost_equivalence(0.62, 0.01, 0.45, 0.55, 0.05).expect("outside the band");
        assert_eq!(strong.verdict, EquivalenceVerdict::AboveBand);
    }

    #[test]
    fn power_plan_uses_variance_effect_and_family_width() {
        let base = plan_paired_mean(PowerPlanRequest {
            alpha: 0.05,
            power: 0.80,
            minimum_detectable_effect: 0.10,
            observed_paired_variance: 0.25,
            sidedness: Sidedness::TwoSided,
            family_hypotheses: 1,
        })
        .expect("a power plan");
        assert!((196..=198).contains(&base.required_pairs));

        let smaller_effect = plan_paired_mean(PowerPlanRequest {
            minimum_detectable_effect: 0.05,
            ..base.request
        })
        .expect("a smaller effect");
        assert!(smaller_effect.required_pairs >= base.required_pairs * 3);

        let family = plan_paired_mean(PowerPlanRequest {
            family_hypotheses: 6,
            ..base.request
        })
        .expect("a family plan");
        assert!(family.required_pairs > base.required_pairs);
    }

    #[test]
    fn equivalence_power_uses_its_own_variance_and_joint_gate_budget() {
        let plan = plan_paired_equivalence(EquivalencePowerPlanRequest {
            alpha: 0.05,
            joint_power: 0.90,
            half_width: 0.05,
            observed_paired_variance: 1.0,
            family_hypotheses: 56,
            independent_confirmatory_gates: 112,
        })
        .expect("an equivalence power plan");
        assert!(plan.required_pairs > 10_000);
        assert!(plan.per_gate_power > 0.999);

        let optimistic_variance = plan_paired_equivalence(EquivalencePowerPlanRequest {
            observed_paired_variance: 0.25,
            ..plan.request
        })
        .expect("a lower-variance plan");
        assert!(plan.required_pairs >= optimistic_variance.required_pairs * 3);

        let fewer_joint_gates = plan_paired_equivalence(EquivalencePowerPlanRequest {
            independent_confirmatory_gates: 2,
            ..plan.request
        })
        .expect("a smaller gate family");
        assert!(plan.required_pairs > fewer_joint_gates.required_pairs);
    }

    fn strength<'a>(fit: &'a BradleyTerryFit, name: &str) -> &'a StrengthEstimate {
        fit.strengths
            .iter()
            .find(|strength| strength.competitor == name)
            .expect("a fitted competitor")
    }

    #[test]
    fn bradley_terry_handles_ties_and_anchors_elo() {
        let comparisons = vec![
            BradleyTerryComparison::from_counts("strong", "anchor", 75, 0, 25).expect("games"),
            BradleyTerryComparison::from_counts("even", "anchor", 0, 100, 0).expect("ties"),
            BradleyTerryComparison::from_counts("weak", "anchor", 25, 0, 75).expect("games"),
        ];
        let fit = fit_bradley_terry(
            &comparisons,
            &BradleyTerryConfig {
                ridge: 1e-9,
                ..BradleyTerryConfig::default()
            },
        )
        .expect("a fit");
        assert!(fit.converged);
        assert_eq!(strength(&fit, "anchor").elo, 1200.0);
        assert_eq!(strength(&fit, "anchor").standard_error_elo, 0.0);
        close(strength(&fit, "even").elo, 1200.0, 1e-6);
        close(
            strength(&fit, "strong").elo,
            1200.0 + 400.0 * 3f64.log10(),
            1e-4,
        );
        close(
            strength(&fit, "weak").elo,
            1200.0 - 400.0 * 3f64.log10(),
            1e-4,
        );
        assert!(strength(&fit, "strong").elo_low > 1200.0);
        assert!(strength(&fit, "weak").elo_high < 1200.0);
    }

    #[test]
    fn bradley_terry_rejects_an_unanchored_component() {
        let comparisons = vec![
            BradleyTerryComparison::from_counts("one", "anchor", 1, 0, 1).expect("games"),
            BradleyTerryComparison::from_counts("lost", "island", 1, 0, 1).expect("games"),
        ];
        assert!(matches!(
            fit_bradley_terry(&comparisons, &BradleyTerryConfig::default()),
            Err(ExperimentError::DisconnectedComparisonGraph(_))
        ));
    }

    fn manifest() -> CalibrationManifest {
        CalibrationManifest {
            schema_version: 1,
            controller_version: "brain-a75e595d".into(),
            profile_versions: vec!["duelist-v1".into(), "denier-v1".into()],
            maps: vec!["drydock".into(), "relay".into()],
            economies: vec!["30".into(), "60".into()],
            controller_fingerprint: "fnv64:controller".into(),
            profile_fingerprints: vec![ContentFingerprint {
                name: "roster".into(),
                digest: "fnv64:profiles".into(),
            }],
            map_fingerprints: vec![ContentFingerprint {
                name: "drydock".into(),
                digest: "fnv64:map".into(),
            }],
            economy_fingerprints: vec![ContentFingerprint {
                name: "matched-30".into(),
                digest: "fnv64:economy".into(),
            }],
            seed_pools: vec![
                SeedPool {
                    name: "development".into(),
                    role: SeedPoolRole::Development,
                    namespace: 7,
                    first_seed: 0,
                    count: 1_000,
                },
                SeedPool {
                    name: "holdout".into(),
                    role: SeedPoolRole::Holdout,
                    namespace: 7,
                    first_seed: 10_000,
                    count: 1_000,
                },
            ],
            hypotheses: vec![HypothesisSpec {
                id: "skill-order".into(),
                description: "The higher tier wins more often".into(),
                kind: HypothesisKind::Superiority {
                    minimum_effect: 0.03,
                },
            }],
            alpha: 0.05,
            power: 0.90,
            samples: vec![SamplePlan {
                hypothesis_id: "skill-order".into(),
                paired_scenarios: 800,
            }],
        }
    }

    #[test]
    fn manifest_and_report_preserve_the_experiment_contract() {
        let manifest = manifest();
        manifest.validate().expect("a complete manifest");
        let report = CalibrationReport {
            manifest,
            evaluated_seed_pools: vec!["holdout".into()],
            paired_observations: 800,
            estimates: vec![HypothesisResult {
                hypothesis_id: "skill-order".into(),
                paired_scenarios: 800,
                estimate: EstimateWithUncertainty {
                    estimate: 0.56,
                    standard_error: 0.012,
                    confidence: 0.95,
                    low: 0.536,
                    high: 0.584,
                },
                raw_p: Some(0.001),
                adjusted_p: Some(0.001),
                verdict: HypothesisVerdict::Passed,
            }],
            strengths: None,
        };
        report.validate().expect("a complete report");
    }

    #[test]
    fn manifest_refuses_overlapping_seed_pools() {
        let mut manifest = manifest();
        manifest.seed_pools[1].first_seed = 500;
        assert!(matches!(
            manifest.validate(),
            Err(ExperimentError::OverlappingSeedPools(_, _))
        ));
    }

    #[test]
    fn manifest_requires_content_fingerprints() {
        let mut missing_controller = manifest();
        missing_controller.controller_fingerprint.clear();
        assert!(matches!(
            missing_controller.validate(),
            Err(ExperimentError::Empty("controller fingerprint"))
        ));

        let mut missing_profile = manifest();
        missing_profile.profile_fingerprints[0].digest.clear();
        assert!(matches!(
            missing_profile.validate(),
            Err(ExperimentError::Empty("profile fingerprints"))
        ));
    }

    #[test]
    fn paired_mean_test_uses_whole_observations() {
        let test = paired_mean_test(&[0.60, 0.55, 0.65, 0.60], 0.50).expect("a mean test");
        assert_eq!(test.observations, 4);
        close(test.estimate, 0.60, 1e-12);
        assert!(test.greater_p < 0.01);
    }

    #[test]
    fn normal_approximations_are_accurate_at_the_design_quantiles() {
        close(inverse_normal(0.975), 1.959_963_984_540_054, 1e-8);
        close(normal_cdf(1.959_963_984_540_054), 0.975, 1e-7);
    }
}
