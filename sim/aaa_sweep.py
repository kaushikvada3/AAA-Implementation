#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import math
import random
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / "sim" / "output"
DEFAULT_NS3_DIR = DEFAULT_OUTPUT_DIR / "ns3"
LIGHT_SPEED_MPS = 299_792_458.0
FREQUENCY_HZ = 2.412e9


@dataclass(frozen=True)
class ScenarioConfig:
    bob_distance_m: float = 18.0
    reference_distance_m: float = 45.0
    tx_power_dbm: float = -3.0
    path_loss_exponent: float = 2.35
    sensitivity_dbm: float = -81.0
    logistic_width_db: float = 2.6
    shared_shadowing_sigma_db: float = 0.8
    independent_shadowing_sigma_db: float = 0.2
    num_rounds: int = 400
    seed: int = 20260326


def parse_distance_list(raw: str) -> list[float]:
    return [float(item.strip()) for item in raw.split(",") if item.strip()]


def friis_reference_loss_db(distance_m: float = 1.0) -> float:
    wavelength_m = LIGHT_SPEED_MPS / FREQUENCY_HZ
    return 20.0 * math.log10((4.0 * math.pi * distance_m) / wavelength_m)


def rx_power_dbm(
    tx_power_dbm: float,
    distance_m: float,
    exponent: float,
    reference_loss_db: float,
    reference_distance_m: float = 1.0,
) -> float:
    clipped_distance = max(distance_m, reference_distance_m)
    loss_db = reference_loss_db + 10.0 * exponent * math.log10(clipped_distance / reference_distance_m)
    return tx_power_dbm - loss_db


def success_probability(rx_dbm: float, sensitivity_dbm: float, logistic_width_db: float) -> float:
    margin_db = rx_dbm - sensitivity_dbm
    return 1.0 / (1.0 + math.exp(-(margin_db / logistic_width_db)))


def write_csv(path: Path, rows: list[dict[str, object]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def pct(raw: object) -> str:
    return f"{100.0 * float(raw):.1f}"


def simulate_fallback_distance(
    distance_m: float,
    config: ScenarioConfig,
    reference_loss_db: float,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    bob_mean_rx_dbm = rx_power_dbm(
        config.tx_power_dbm,
        config.bob_distance_m,
        config.path_loss_exponent,
        reference_loss_db,
    )
    eve_mean_rx_dbm = rx_power_dbm(
        config.tx_power_dbm,
        distance_m,
        config.path_loss_exponent,
        reference_loss_db,
    )
    rng = random.Random(config.seed + int(distance_m * 10))
    round_rows: list[dict[str, object]] = []
    bob_rx = 0
    eve_rx = 0
    secure_rounds = 0
    first_secure_round = 0

    for round_index in range(1, config.num_rounds + 1):
        common_shadowing_db = rng.gauss(0.0, config.shared_shadowing_sigma_db)
        bob_shadowing_db = common_shadowing_db + rng.gauss(0.0, config.independent_shadowing_sigma_db)
        eve_shadowing_db = common_shadowing_db + rng.gauss(0.0, config.independent_shadowing_sigma_db)
        bob_prob = success_probability(
            bob_mean_rx_dbm + bob_shadowing_db,
            config.sensitivity_dbm,
            config.logistic_width_db,
        )
        eve_prob = success_probability(
            eve_mean_rx_dbm + eve_shadowing_db,
            config.sensitivity_dbm,
            config.logistic_width_db,
        )
        bob_received = int(rng.random() < bob_prob)
        eve_received = int(rng.random() < eve_prob)
        secure_round = int(bob_received == 1 and eve_received == 0)

        bob_rx += bob_received
        eve_rx += eve_received
        secure_rounds += secure_round
        if secure_round and not first_secure_round:
            first_secure_round = round_index

        conditional_mu = (secure_rounds / bob_rx) if bob_rx else 0.0
        cumulative_equivocation = 1.0 - math.pow(1.0 - conditional_mu, bob_rx) if bob_rx else 0.0

        round_rows.append(
            {
                "engine": "fallback",
                "distance_m": f"{distance_m:.1f}",
                "round": round_index,
                "bob_received": bob_received,
                "eve_received": eve_received,
                "secure_round": secure_round,
                "key_secure_after_round": int(secure_rounds > 0),
                "cumulative_bob_rx": bob_rx,
                "cumulative_secure_rounds": secure_rounds,
                "cumulative_equivocation": f"{cumulative_equivocation:.6f}",
            }
        )

    summary_row = {
        "engine": "fallback",
        "distance_m": f"{distance_m:.1f}",
        "num_rounds": config.num_rounds,
        "bob_rx": bob_rx,
        "eve_rx": eve_rx,
        "secure_rounds": secure_rounds,
        "availability": f"{(bob_rx / config.num_rounds):.6f}",
        "secrecy_rate": f"{(secure_rounds / config.num_rounds):.6f}",
        "eve_capture_rate": f"{(eve_rx / config.num_rounds):.6f}",
        "conditional_eve_miss": f"{(secure_rounds / bob_rx) if bob_rx else 0.0:.6f}",
        "first_secure_round": first_secure_round,
        "final_equivocation": round_rows[-1]["cumulative_equivocation"] if round_rows else "0.000000",
        "bob_rx_power_dbm": f"{bob_mean_rx_dbm:.3f}",
        "eve_rx_power_dbm": f"{eve_mean_rx_dbm:.3f}",
    }
    return round_rows, summary_row


def load_round_rows(path: Path) -> list[dict[str, object]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def summarize_round_rows(
    round_rows: list[dict[str, object]],
    distance_m: float,
    config: ScenarioConfig,
    reference_loss_db: float,
    engine: str,
) -> dict[str, object]:
    bob_rx = sum(int(row["bob_received"]) for row in round_rows)
    eve_rx = sum(int(row["eve_received"]) for row in round_rows)
    secure_rounds = sum(int(row["secure_round"]) for row in round_rows)
    first_secure_round = 0
    for row in round_rows:
        if int(row["secure_round"]) == 1:
            first_secure_round = int(row["round"])
            break

    bob_mean_rx_dbm = rx_power_dbm(
        config.tx_power_dbm,
        config.bob_distance_m,
        config.path_loss_exponent,
        reference_loss_db,
    )
    eve_mean_rx_dbm = rx_power_dbm(
        config.tx_power_dbm,
        distance_m,
        config.path_loss_exponent,
        reference_loss_db,
    )

    return {
        "engine": engine,
        "distance_m": f"{distance_m:.1f}",
        "num_rounds": len(round_rows),
        "bob_rx": bob_rx,
        "eve_rx": eve_rx,
        "secure_rounds": secure_rounds,
        "availability": f"{(bob_rx / len(round_rows)) if round_rows else 0.0:.6f}",
        "secrecy_rate": f"{(secure_rounds / len(round_rows)) if round_rows else 0.0:.6f}",
        "eve_capture_rate": f"{(eve_rx / len(round_rows)) if round_rows else 0.0:.6f}",
        "conditional_eve_miss": f"{(secure_rounds / bob_rx) if bob_rx else 0.0:.6f}",
        "first_secure_round": first_secure_round,
        "final_equivocation": (
            f"{float(round_rows[-1]['cumulative_equivocation']):.6f}" if round_rows else "0.000000"
        ),
        "bob_rx_power_dbm": f"{bob_mean_rx_dbm:.3f}",
        "eve_rx_power_dbm": f"{eve_mean_rx_dbm:.3f}",
    }


def load_ns3_results(
    ns3_dir: Path,
    config: ScenarioConfig,
    reference_loss_db: float,
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    round_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for path in sorted(ns3_dir.glob("ns3_rounds_eve_*.csv")):
        rows = load_round_rows(path)
        if not rows:
            continue
        distance_m = float(rows[0]["distance_m"])
        round_rows.extend(rows)
        summary_rows.append(
            summarize_round_rows(rows, distance_m, config, reference_loss_db, engine="ns3")
        )
    return round_rows, summary_rows


def build_validation_rows(summary_rows: list[dict[str, object]]) -> list[dict[str, object]]:
    grouped: dict[float, dict[str, dict[str, object]]] = {}
    for row in summary_rows:
        distance = float(row["distance_m"])
        grouped.setdefault(distance, {})[str(row["engine"])] = row

    validation_rows: list[dict[str, object]] = []
    for distance in sorted(grouped):
        pair = grouped[distance]
        if "fallback" not in pair or "ns3" not in pair:
            continue
        fallback = pair["fallback"]
        ns3 = pair["ns3"]
        validation_rows.append(
            {
                "distance_m": f"{distance:.1f}",
                "availability_fallback": fallback["availability"],
                "availability_ns3": ns3["availability"],
                "availability_delta": f"{float(ns3['availability']) - float(fallback['availability']):.6f}",
                "secrecy_rate_fallback": fallback["secrecy_rate"],
                "secrecy_rate_ns3": ns3["secrecy_rate"],
                "secrecy_rate_delta": f"{float(ns3['secrecy_rate']) - float(fallback['secrecy_rate']):.6f}",
                "final_equivocation_fallback": fallback["final_equivocation"],
                "final_equivocation_ns3": ns3["final_equivocation"],
            }
        )
    return validation_rows


def choose_reference_rows(
    round_rows: list[dict[str, object]],
    preferred_engine: str,
    reference_distance_m: float,
) -> list[dict[str, object]]:
    matching_rows = [
        row
        for row in round_rows
        if row["engine"] == preferred_engine and abs(float(row["distance_m"]) - reference_distance_m) < 0.01
    ]
    if matching_rows:
        return matching_rows

    return [
        row
        for row in round_rows
        if row["engine"] == "fallback" and abs(float(row["distance_m"]) - reference_distance_m) < 0.01
    ]


def choose_reference_summary(
    summary_rows: list[dict[str, object]],
    preferred_engine: str,
    reference_distance_m: float,
) -> dict[str, object]:
    for row in summary_rows:
        if row["engine"] == preferred_engine and abs(float(row["distance_m"]) - reference_distance_m) < 0.01:
            return row
    for row in summary_rows:
        if row["engine"] == "fallback" and abs(float(row["distance_m"]) - reference_distance_m) < 0.01:
            return row
    raise ValueError("Reference summary row not found")


def write_reference_snippet(path: Path, reference_rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in reference_rows[:8]:
            handle.write(
                "{} & {} & {} & {} & {} & {:.3f} \\\\\n".format(
                    row["round"],
                    row["bob_received"],
                    row["eve_received"],
                    row["secure_round"],
                    row["key_secure_after_round"],
                    float(row["cumulative_equivocation"]),
                )
            )


def write_metrics_snippet(
    path: Path,
    config: ScenarioConfig,
    summary_rows: list[dict[str, object]],
    validation_rows: list[dict[str, object]],
    reference_summary: dict[str, object],
    has_ns3: bool,
) -> None:
    preferred_engine = "ns3" if has_ns3 else "fallback"
    preferred_rows = [row for row in summary_rows if row["engine"] == preferred_engine]
    peak_row = max(preferred_rows, key=lambda row: float(row["secrecy_rate"]))
    late_row = preferred_rows[-1]

    availability_delta = 0.0
    secrecy_delta = 0.0
    if validation_rows:
        availability_delta = max(abs(float(row["availability_delta"])) for row in validation_rows)
        secrecy_delta = max(abs(float(row["secrecy_rate_delta"])) for row in validation_rows)

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("\\hasnsthreetrue\n" if has_ns3 else "\\hasnsthreefalse\n")
        handle.write(f"\\renewcommand{{\\BobDistanceMeters}}{{{config.bob_distance_m:.0f}}}\n")
        handle.write(f"\\renewcommand{{\\ReferenceDistanceMeters}}{{{config.reference_distance_m:.0f}}}\n")
        handle.write(f"\\renewcommand{{\\SweepRounds}}{{{config.num_rounds}}}\n")
        label = "ns-3" if reference_summary["engine"] == "ns3" else "fallback"
        handle.write(f"\\renewcommand{{\\ReferenceEngineLabel}}{{{label}}}\n")
        handle.write(f"\\renewcommand{{\\ReferenceAvailabilityPct}}{{{pct(reference_summary['availability'])}}}\n")
        handle.write(f"\\renewcommand{{\\ReferenceSecrecyPct}}{{{pct(reference_summary['secrecy_rate'])}}}\n")
        handle.write(f"\\renewcommand{{\\ReferenceEquivocation}}{{{float(reference_summary['final_equivocation']):.3f}}}\n")
        handle.write(f"\\renewcommand{{\\ReferenceFirstSecureRound}}{{{reference_summary['first_secure_round']}}}\n")
        handle.write(f"\\renewcommand{{\\PeakSecrecyDistanceMeters}}{{{float(peak_row['distance_m']):.0f}}}\n")
        handle.write(f"\\renewcommand{{\\PeakSecrecyPct}}{{{pct(peak_row['secrecy_rate'])}}}\n")
        handle.write(f"\\renewcommand{{\\LateDistanceMeters}}{{{float(late_row['distance_m']):.0f}}}\n")
        handle.write(f"\\renewcommand{{\\LateAvailabilityPct}}{{{pct(late_row['availability'])}}}\n")
        handle.write(f"\\renewcommand{{\\LateSecrecyPct}}{{{pct(late_row['secrecy_rate'])}}}\n")
        handle.write(f"\\renewcommand{{\\MaxAvailabilityDeltaPct}}{{{100.0 * availability_delta:.1f}}}\n")
        handle.write(f"\\renewcommand{{\\MaxSecrecyDeltaPct}}{{{100.0 * secrecy_delta:.1f}}}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate AAA fallback and validation sweep CSVs.")
    parser.add_argument(
        "--distances",
        default="10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90",
        help="Comma-separated Eve distances in meters.",
    )
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR), help="Output directory.")
    parser.add_argument("--ns3-dir", default=str(DEFAULT_NS3_DIR), help="Directory containing ns-3 round CSVs.")
    parser.add_argument("--bob-distance", type=float, default=18.0, help="Bob distance in meters.")
    parser.add_argument("--reference-distance", type=float, default=45.0, help="Reference Eve distance in meters.")
    parser.add_argument("--num-rounds", type=int, default=400, help="Packets per sweep point.")
    parser.add_argument("--tx-power-dbm", type=float, default=-3.0, help="Transmit power used by both models.")
    parser.add_argument(
        "--path-loss-exponent",
        type=float,
        default=2.35,
        help="Log-distance exponent used by the fallback model.",
    )
    parser.add_argument("--seed", type=int, default=20260326, help="Base random seed for fallback runs.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    ns3_dir = Path(args.ns3_dir).resolve()
    distances = parse_distance_list(args.distances)
    reference_loss_db = friis_reference_loss_db()

    config = ScenarioConfig(
        bob_distance_m=args.bob_distance,
        reference_distance_m=args.reference_distance,
        tx_power_dbm=args.tx_power_dbm,
        path_loss_exponent=args.path_loss_exponent,
        num_rounds=args.num_rounds,
        seed=args.seed,
    )

    all_round_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for distance_m in distances:
        round_rows, summary_row = simulate_fallback_distance(distance_m, config, reference_loss_db)
        all_round_rows.extend(round_rows)
        summary_rows.append(summary_row)

    ns3_round_rows, ns3_summary_rows = load_ns3_results(ns3_dir, config, reference_loss_db)
    all_round_rows.extend(ns3_round_rows)
    summary_rows.extend(ns3_summary_rows)

    round_fieldnames = [
        "engine",
        "distance_m",
        "round",
        "bob_received",
        "eve_received",
        "secure_round",
        "key_secure_after_round",
        "cumulative_bob_rx",
        "cumulative_secure_rounds",
        "cumulative_equivocation",
    ]
    summary_fieldnames = [
        "engine",
        "distance_m",
        "num_rounds",
        "bob_rx",
        "eve_rx",
        "secure_rounds",
        "availability",
        "secrecy_rate",
        "eve_capture_rate",
        "conditional_eve_miss",
        "first_secure_round",
        "final_equivocation",
        "bob_rx_power_dbm",
        "eve_rx_power_dbm",
    ]
    validation_rows = build_validation_rows(summary_rows)
    validation_fieldnames = [
        "distance_m",
        "availability_fallback",
        "availability_ns3",
        "availability_delta",
        "secrecy_rate_fallback",
        "secrecy_rate_ns3",
        "secrecy_rate_delta",
        "final_equivocation_fallback",
        "final_equivocation_ns3",
    ]

    all_round_rows.sort(key=lambda row: (row["engine"], float(row["distance_m"]), int(row["round"])))
    summary_rows.sort(key=lambda row: (row["engine"], float(row["distance_m"])))
    validation_rows.sort(key=lambda row: float(row["distance_m"]))

    write_csv(output_dir / "sweep_rounds.csv", all_round_rows, round_fieldnames)
    write_csv(output_dir / "sweep_results.csv", summary_rows, summary_fieldnames)
    write_csv(
        output_dir / "sweep_results_fallback.csv",
        [row for row in summary_rows if row["engine"] == "fallback"],
        summary_fieldnames,
    )
    write_csv(
        output_dir / "sweep_results_ns3.csv",
        [row for row in summary_rows if row["engine"] == "ns3"],
        summary_fieldnames,
    )
    write_csv(output_dir / "validation_summary.csv", validation_rows, validation_fieldnames)

    preferred_engine = "ns3" if ns3_round_rows else "fallback"
    reference_rows = choose_reference_rows(all_round_rows, preferred_engine, config.reference_distance_m)[:12]
    reference_summary = choose_reference_summary(summary_rows, preferred_engine, config.reference_distance_m)
    write_csv(output_dir / "reference_run.csv", reference_rows, round_fieldnames)
    write_reference_snippet(ROOT / "report" / "generated" / "reference_run_rows.tex", reference_rows)
    write_metrics_snippet(
        ROOT / "report" / "generated" / "metrics.tex",
        config,
        summary_rows,
        validation_rows,
        reference_summary,
        has_ns3=bool(ns3_round_rows),
    )

    print(f"Wrote {output_dir / 'sweep_results.csv'}")
    if ns3_round_rows:
        print(f"Loaded ns-3 rounds from {ns3_dir}")
    else:
        print(f"No ns-3 round CSVs found under {ns3_dir}; fallback-only outputs generated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
