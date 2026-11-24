#!/usr/bin/env python3

"""
create_master_report.py

Create the top-level influenza master report by combining:

    1. nf-fluab summary_report.csv
    2. Read-level QC report (reads.qcreport.csv)

Join keys:
    Read QC: sample, platform
    Summary uniqueness: sample, platform, ref_subtype

A sample can have multiple reference-subtype results (coinfection).
The read QC record is repeated for each matching subtype result.

Pipeline versions:
    nf_qcflow_ver
    flu_analyzer_ver

Join behavior:
    - Matching sample/platform: combine the two reports.
    - Read QC without consensus results: retain the read QC record
      and fill influenza analysis columns with "NA".
    - Summary without a read QC record: retain the summary record
      and fill read QC columns with "NA".

Input and output files are comma-separated CSV files.
"""

import argparse
import csv
from collections import defaultdict


JOIN_COLUMNS = [
    "sample",
    "platform",
]

UNIQUE_COLUMNS = [
    "sample",
    "platform",
    "ref_subtype",
]

VERSION_COLUMNS = [
    "nf_qcflow_ver",
    "flu_analyzer_ver",
]


def read_csv(path):
    """Read a CSV file and return its rows and column names."""

    with open(path, "r", newline="") as in_f:
        reader = csv.DictReader(in_f)

        fieldnames = reader.fieldnames or []

        if not fieldnames:
            raise ValueError(
                f"Input file has no header: {path}"
            )

        rows = list(reader)

    return rows, fieldnames


def validate_columns(path, fieldnames, required_columns):
    """Check that required columns are present."""

    missing = [
        column
        for column in required_columns
        if column not in fieldnames
    ]

    if missing:
        raise ValueError(
            f"Missing required columns in {path}: "
            f"{', '.join(missing)}"
        )


def get_join_key(row, path, row_number):
    """Return the sample/platform join key."""

    sample = (row.get("sample") or "").strip()
    platform = (row.get("platform") or "").strip()

    if not sample or not platform:
        raise ValueError(
            f"Missing sample or platform in {path}, "
            f"row {row_number}"
        )

    return sample, platform


def read_read_qc_report(path):
    """
    Read read QC records and index them by sample/platform.

    Each sample/platform combination must have exactly one read QC
    record.
    """

    rows, fieldnames = read_csv(path)

    validate_columns(
        path,
        fieldnames,
        JOIN_COLUMNS,
    )

    records = {}

    for row_number, row in enumerate(rows, start=2):
        key = get_join_key(
            row,
            path,
            row_number,
        )

        if key in records:
            raise ValueError(
                "Multiple read QC records found for the same "
                "sample/platform combination:\n"
                f"  sample: {key[0]}\n"
                f"  platform: {key[1]}\n"
                f"  file: {path}"
            )

        records[key] = row

    return records, fieldnames


def read_summary_report(path):
    """
    Read nf-fluab summary records and group them by sample/platform.

    Each sample/platform/ref_subtype combination must be unique.
    Multiple subtype results for the same sample/platform are allowed.
    """

    rows, fieldnames = read_csv(path)

    validate_columns(
        path,
        fieldnames,
        UNIQUE_COLUMNS,
    )

    records = defaultdict(list)
    seen = set()

    for row_number, row in enumerate(rows, start=2):
        sample, platform = get_join_key(
            row,
            path,
            row_number,
        )

        ref_subtype = (row.get("ref_subtype") or "").strip()

        if not ref_subtype:
            raise ValueError(
                f"Missing ref_subtype in {path}, "
                f"row {row_number}"
            )

        unique_key = (
            sample,
            platform,
            ref_subtype,
        )

        if unique_key in seen:
            raise ValueError(
                "Duplicate sample/platform/ref_subtype combination:\n"
                f"  sample: {sample}\n"
                f"  platform: {platform}\n"
                f"  ref_subtype: {ref_subtype}\n"
                f"  file: {path}\n"
                f"  row: {row_number}"
            )

        seen.add(unique_key)

        records[(sample, platform)].append(row)

    return records, fieldnames


def build_master_report(
    summary_records,
    summary_columns,
    read_qc_records,
    read_qc_columns,
    nf_qcflow_ver,
    flu_analyzer_ver,
):
    """
    Combine summary and read QC records using a full outer join.

    The output contains one row per unique
    sample/platform/ref_subtype combination.

    A read QC record without a matching summary record produces
    one row with ref_subtype and influenza analysis fields set to "NA".
    """

    output_columns = (
        JOIN_COLUMNS
        + [
            column
            for column in read_qc_columns
            if column not in JOIN_COLUMNS
        ]
        + [
            column
            for column in summary_columns
            if column not in JOIN_COLUMNS
        ]
        + VERSION_COLUMNS
    )

    rows = []

    all_keys = list(read_qc_records)

    # Append summary-only sample/platform combinations.
    all_keys.extend(
        key
        for key in summary_records
        if key not in read_qc_records
    )

    for key in all_keys:
        sample, platform = key

        read_qc_record = read_qc_records.get(
            key,
            {},
        )

        summary_matches = summary_records.get(
            key,
            [],
        )

        # Retain read QC records without consensus results.
        if not summary_matches:
            summary_matches = [{}]

        for summary_record in summary_matches:
            row = {
                "sample": sample,
                "platform": platform,
            }

            # Add read QC fields.
            for column in read_qc_columns:
                if column in JOIN_COLUMNS:
                    continue

                value = read_qc_record.get(column, "")
                row[column] = (
                    value if value not in (None, "") else "NA"
                )

            # Add nf-fluab summary fields.
            for column in summary_columns:
                if column in JOIN_COLUMNS:
                    continue

                value = summary_record.get(column, "")
                row[column] = (
                    value if value not in (None, "") else "NA"
                )

            # Add pipeline versions.
            row["nf_qcflow_ver"] = nf_qcflow_ver
            row["flu_analyzer_ver"] = flu_analyzer_ver

            rows.append(row)

    return rows, output_columns


def write_master_report(rows, columns, output):
    """Write the master report as a CSV file."""

    with open(output, "w", newline="") as out_f:
        writer = csv.DictWriter(
            out_f,
            fieldnames=columns,
            extrasaction="ignore",
        )

        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Create a master influenza report by combining "
            "the nf-fluab summary report and read QC report."
        )
    )

    parser.add_argument(
        "--summary-report",
        required=True,
        help="nf-fluab summary_report.csv.",
    )

    parser.add_argument(
        "--read-qc-report",
        required=True,
        help="Read QC report CSV.",
    )

    parser.add_argument(
        "--nf-qcflow-ver",
        required=True,
        help="nf-qcflow pipeline version.",
    )

    parser.add_argument(
        "--flu-analyzer-ver",
        required=True,
        help="flu-analyzer version.",
    )

    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output master report CSV.",
    )

    args = parser.parse_args()

    summary_records, summary_columns = read_summary_report(
        args.summary_report
    )

    read_qc_records, read_qc_columns = read_read_qc_report(
        args.read_qc_report
    )

    rows, output_columns = build_master_report(
        summary_records=summary_records,
        summary_columns=summary_columns,
        read_qc_records=read_qc_records,
        read_qc_columns=read_qc_columns,
        nf_qcflow_ver=args.nf_qcflow_ver,
        flu_analyzer_ver=args.flu_analyzer_ver,
    )

    write_master_report(
        rows=rows,
        columns=output_columns,
        output=args.output,
    )

    print(
        f"Created master report: {args.output}",
        flush=True,
    )

    print(
        f"  Read QC sample/platform combinations: "
        f"{len(read_qc_records)}",
        flush=True,
    )

    print(
        f"  Summary sample/platform combinations: "
        f"{len(summary_records)}",
        flush=True,
    )

    print(
        f"  Master report rows: {len(rows)}",
        flush=True,
    )

    print(
        f"  nf-qcflow version: {args.nf_qcflow_ver}",
        flush=True,
    )

    print(
        f"  flu-analyzer version: {args.flu_analyzer_ver}",
        flush=True,
    )


if __name__ == "__main__":
    main()
