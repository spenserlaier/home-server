#!/usr/bin/env python3
"""Convert a small Invoice Ninja mysqldump into an InvoiceShelf SQL import.

The generated SQL contains private invoice data. Write it outside the repository
(the default is /private/tmp/invoiceshelf-import.sql) and delete it after use.
Import it only into an empty InvoiceShelf database; the migration is not safe to
rerun. The converter refuses to replace an existing output file.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path


TABLES = (
    "countries",
    "clients",
    "client_contacts",
    "invoices",
    "payments",
    "paymentables",
)


@dataclass
class DumpTable:
    columns: list[str]
    rows: list[dict[str, str | None]]


def mysql_unescape(value: str) -> str:
    escapes = {
        "0": "\0",
        "b": "\b",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "Z": "\x1a",
        "\\": "\\",
        "'": "'",
        '"': '"',
    }
    result: list[str] = []
    index = 0
    while index < len(value):
        char = value[index]
        if char == "\\" and index + 1 < len(value):
            index += 1
            result.append(escapes.get(value[index], value[index]))
        else:
            result.append(char)
        index += 1
    return "".join(result)


def parse_values(source: str) -> list[list[str | None]]:
    rows: list[list[str | None]] = []
    row: list[str | None] = []
    token: list[str] = []
    depth = 0
    quoted = False
    escaped = False
    token_was_quoted = False

    def finish_token() -> str | None:
        raw = "".join(token)
        if token_was_quoted:
            return mysql_unescape(raw)
        raw = raw.strip()
        return None if raw.upper() == "NULL" else raw

    for char in source:
        if quoted:
            if escaped:
                token.extend(("\\", char))
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "'":
                quoted = False
            else:
                token.append(char)
            continue

        if char == "'":
            quoted = True
            token_was_quoted = True
        elif char == "(":
            if depth == 0:
                row = []
                token = []
                token_was_quoted = False
            else:
                token.append(char)
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                row.append(finish_token())
                rows.append(row)
                token = []
                token_was_quoted = False
            else:
                token.append(char)
        elif char == "," and depth == 1:
            row.append(finish_token())
            token = []
            token_was_quoted = False
        elif depth:
            token.append(char)

    if quoted or depth:
        raise ValueError("unterminated INSERT statement")
    return rows


def load_table(dump: str, table: str) -> DumpTable:
    create = re.search(rf"CREATE TABLE `{re.escape(table)}` \((.*?)\) ENGINE=", dump, re.S)
    if not create:
        raise ValueError(f"missing CREATE TABLE for {table}")
    columns = re.findall(r"^  `([^`]+)` ", create.group(1), re.M)

    marker = f"INSERT INTO `{table}` VALUES\n"
    start = dump.find(marker)
    if start < 0:
        return DumpTable(columns, [])
    start += len(marker)
    end = dump.find(";\n", start)
    if end < 0:
        raise ValueError(f"unterminated INSERT for {table}")

    values = parse_values(dump[start:end])
    if any(len(row) != len(columns) for row in values):
        raise ValueError(f"column count mismatch in {table}")
    return DumpTable(columns, [dict(zip(columns, row)) for row in values])


def sql_text(value: object | None) -> str:
    if value is None or value == "":
        return "NULL"
    encoded = str(value).encode("utf-8").hex()
    return f"CONVERT(0x{encoded} USING utf8mb4)"


def sql_date(value: object | None, fallback: str = "1970-01-01") -> str:
    if value is None or value == "":
        value = fallback
    return sql_text(str(value)[:10])


def cents(value: object | None) -> int:
    if value is None or value == "":
        return 0
    return int((Decimal(str(value)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def decimal_sql(value: object | None, fallback: str = "0") -> str:
    candidate = fallback if value is None or value == "" else str(value)
    return format(Decimal(candidate), "f")


def is_true(value: object | None) -> bool:
    return str(value or "0") == "1"


def append_insert(lines: list[str], table: str, fields: dict[str, str]) -> None:
    lines.append(
        f"INSERT INTO `{table}` ({', '.join(f'`{name}`' for name in fields)})\n"
        f"VALUES ({', '.join(fields.values())});"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/private/tmp/invoiceshelf-import.sql"),
    )
    parser.add_argument("--company-id", type=int, default=1)
    parser.add_argument("--creator-id", type=int, default=1)
    parser.add_argument("--currency-id", type=int, default=4)
    parser.add_argument("--payment-method-id", type=int, default=4)
    args = parser.parse_args()

    dump = args.source.read_text(encoding="utf-8")
    tables = {name: load_table(dump, name) for name in TABLES}

    clients = [row for row in tables["clients"].rows if not is_true(row["is_deleted"])]
    if len(clients) != 1:
        raise ValueError(f"expected exactly one active client, found {len(clients)}")
    client = clients[0]
    source_client_id = client["id"]
    contacts = [
        row
        for row in tables["client_contacts"].rows
        if row["client_id"] == source_client_id and row["deleted_at"] is None
    ]
    contact = next((row for row in contacts if is_true(row["is_primary"])), contacts[0] if contacts else {})

    country_by_id = {row["id"]: row["iso_3166_2"] for row in tables["countries"].rows}
    country_code = country_by_id.get(client["country_id"])

    invoices = [
        row
        for row in tables["invoices"].rows
        if row["client_id"] == source_client_id and not is_true(row["is_deleted"])
    ]
    invoices.sort(key=lambda row: (str(row["date"] or ""), int(str(row["id"]))))
    source_invoice_ids = {row["id"] for row in invoices}

    payments_by_id = {
        row["id"]: row
        for row in tables["payments"].rows
        if row["client_id"] == source_client_id
        and not is_true(row["is_deleted"])
        and row["deleted_at"] is None
    }
    allocations = [
        row
        for row in tables["paymentables"].rows
        if row["payment_id"] in payments_by_id
        and row["paymentable_id"] in source_invoice_ids
        and row["deleted_at"] is None
        and str(row["paymentable_type"] or "").lower() in {"invoices", "app\\models\\invoice"}
    ]
    allocations.sort(key=lambda row: (payments_by_id[row["payment_id"]]["date"] or "", int(str(row["id"]))))

    lines = [
        "-- Generated from an Invoice Ninja dump; contains private business data.",
        "-- Import only into the intended InvoiceShelf database.",
        "SET NAMES utf8mb4;",
        "SET @migration_company_id = " + str(args.company_id) + ";",
        "SET @migration_creator_id = " + str(args.creator_id) + ";",
        "SET @migration_currency_id = " + str(args.currency_id) + ";",
        "SET @migration_payment_method_id = " + str(args.payment_method_id) + ";",
        "START TRANSACTION;",
    ]

    contact_name = " ".join(
        part for part in (contact.get("first_name"), contact.get("last_name")) if part
    ) or None
    append_insert(
        lines,
        "customers",
        {
            "name": sql_text(client["name"] or contact_name or "Migrated customer"),
            "email": sql_text(contact.get("email")),
            "phone": sql_text(contact.get("phone") or client["phone"]),
            "contact_name": sql_text(contact_name),
            "company_name": sql_text(client["name"]),
            "enable_portal": "0",
            "currency_id": "@migration_currency_id",
            "company_id": "@migration_company_id",
            "creator_id": "@migration_creator_id",
            "created_at": "CURRENT_TIMESTAMP",
            "updated_at": "CURRENT_TIMESTAMP",
        },
    )
    lines.append("SET @migration_customer_id = LAST_INSERT_ID();")

    if any(client.get(field) for field in ("address1", "address2", "city", "state", "postal_code")):
        country_expression = (
            f"(SELECT `id` FROM `countries` WHERE BINARY `code` = BINARY {sql_text(country_code)} LIMIT 1)"
            if country_code
            else "NULL"
        )
        append_insert(
            lines,
            "addresses",
            {
                "name": sql_text(client["name"]),
                "address_street_1": sql_text(client["address1"]),
                "address_street_2": sql_text(client["address2"]),
                "city": sql_text(client["city"]),
                "state": sql_text(client["state"]),
                "country_id": country_expression,
                "zip": sql_text(client["postal_code"]),
                "phone": sql_text(contact.get("phone") or client["phone"]),
                "type": sql_text("billing"),
                "company_id": "@migration_company_id",
                "customer_id": "@migration_customer_id",
                "created_at": "CURRENT_TIMESTAMP",
                "updated_at": "CURRENT_TIMESTAMP",
            },
        )

    invoice_vars: dict[str | None, str] = {}
    paid_count = partial_count = unpaid_count = item_count = 0
    for sequence, invoice in enumerate(invoices, start=1):
        amount = cents(invoice["amount"])
        balance = cents(invoice["balance"])
        paid_to_date = cents(invoice["paid_to_date"])
        if balance <= 0 and (paid_to_date > 0 or amount == 0):
            status, paid_status = "COMPLETED", "PAID"
            paid_count += 1
        elif paid_to_date > 0 and balance > 0:
            status, paid_status = "SENT", "PARTIALLY_PAID"
            partial_count += 1
        else:
            # Invoice Ninja status 1 is DRAFT; an unpaid status by itself does
            # not establish whether an invoice was ever sent.
            status = "DRAFT" if str(invoice["status_id"]) == "1" else "SENT"
            paid_status = "UNPAID"
            unpaid_count += 1

        # Invoice Ninja keeps a draft's balance at zero until it is sent, while
        # InvoiceShelf expects an unpaid draft's due amount to equal its total.
        destination_due = amount if status == "DRAFT" and paid_status == "UNPAID" else max(balance, 0)

        items = json.loads(str(invoice["line_items"] or "[]"))
        gross_total = sum(
            (cents(Decimal(str(item.get("cost") or 0)) * Decimal(str(item.get("quantity") or 0))) for item in items),
            0,
        )
        tax_total = sum((cents(item.get("tax_amount")) for item in items), 0)
        discount_total = gross_total + tax_total - amount
        has_item_tax = any(cents(item.get("tax_amount")) for item in items)
        has_item_discount = any(
            cents(Decimal(str(item.get("cost") or 0)) * Decimal(str(item.get("quantity") or 0)))
            + cents(item.get("tax_amount"))
            != cents(item.get("line_total"))
            for item in items
        )
        variable = f"@migration_invoice_{sequence}"
        invoice_vars[invoice["id"]] = variable
        append_insert(
            lines,
            "invoices",
            {
                "sequence_number": str(sequence),
                "customer_sequence_number": str(sequence),
                "invoice_date": sql_date(invoice["date"]),
                "due_date": sql_date(invoice["due_date"]) if invoice["due_date"] else "NULL",
                "invoice_number": sql_text(invoice["number"] or f"MIGRATED-{sequence:04d}"),
                "status": sql_text(status),
                "paid_status": sql_text(paid_status),
                "tax_per_item": sql_text("YES" if has_item_tax else "NO"),
                "discount_per_item": sql_text("YES" if has_item_discount else "NO"),
                "notes": sql_text(invoice["public_notes"]),
                "discount_type": sql_text("fixed"),
                "discount": decimal_sql(invoice["discount"]),
                "discount_val": str(discount_total),
                "sub_total": str(gross_total),
                "total": str(amount),
                "tax": str(tax_total),
                "due_amount": str(destination_due),
                "sent": "0" if status == "DRAFT" else "1",
                "viewed": "0",
                "unique_hash": "LOWER(HEX(RANDOM_BYTES(20)))",
                "company_id": "@migration_company_id",
                "creator_id": "@migration_creator_id",
                "template_name": sql_text("invoice1"),
                "customer_id": "@migration_customer_id",
                "exchange_rate": decimal_sql(invoice["exchange_rate"], "1"),
                "base_discount_val": str(discount_total),
                "base_sub_total": str(gross_total),
                "base_total": str(amount),
                "base_tax": str(tax_total),
                "base_due_amount": str(destination_due),
                "currency_id": "@migration_currency_id",
                "overdue": "0",
                "tax_included": "1" if is_true(invoice["uses_inclusive_taxes"]) else "0",
                "created_at": sql_text(invoice["created_at"]),
                "updated_at": sql_text(invoice["updated_at"]),
            },
        )
        lines.append(f"SET {variable} = LAST_INSERT_ID();")

        for item in items:
            item_count += 1
            price = cents(item.get("cost"))
            quantity = decimal_sql(item.get("quantity"), "1")
            gross = cents(Decimal(str(item.get("cost") or 0)) * Decimal(str(item.get("quantity") or 0)))
            tax = cents(item.get("tax_amount"))
            total = cents(item.get("line_total"))
            item_discount = gross + tax - total
            append_insert(
                lines,
                "invoice_items",
                {
                    "name": sql_text(item.get("product_key") or "Service"),
                    "description": sql_text(item.get("notes")),
                    "discount_type": sql_text("fixed"),
                    "price": str(price),
                    "quantity": quantity,
                    # Invoice Ninja stores UN/CEFACT code C62 ("one") on these
                    # service lines. InvoiceShelf renders unit_name beside the
                    # quantity, so importing it produces a distracting suffix.
                    "unit_name": "NULL",
                    "discount": "0",
                    "discount_val": str(item_discount),
                    "tax": str(tax),
                    "total": str(total),
                    "invoice_id": variable,
                    "company_id": "@migration_company_id",
                    "created_at": "CURRENT_TIMESTAMP",
                    "updated_at": "CURRENT_TIMESTAMP",
                    "base_price": str(price),
                    "exchange_rate": decimal_sql(invoice["exchange_rate"], "1"),
                    "base_discount_val": str(item_discount),
                    "base_tax": str(tax),
                    "base_total": str(total),
                },
            )

    for sequence, allocation in enumerate(allocations, start=1):
        payment = payments_by_id[allocation["payment_id"]]
        invoice_variable = invoice_vars[allocation["paymentable_id"]]
        append_insert(
            lines,
            "payments",
            {
                "sequence_number": str(sequence),
                "customer_sequence_number": str(sequence),
                "payment_number": sql_text(payment["number"] or f"MIGRATED-PAY-{sequence:04d}"),
                "payment_date": sql_date(payment["date"]),
                "notes": sql_text(payment["private_notes"]),
                "amount": str(cents(allocation["amount"])),
                "unique_hash": "LOWER(HEX(RANDOM_BYTES(20)))",
                "invoice_id": invoice_variable,
                "company_id": "@migration_company_id",
                "payment_method_id": "@migration_payment_method_id",
                "created_at": sql_text(payment["created_at"]),
                "updated_at": sql_text(payment["updated_at"]),
                "creator_id": "@migration_creator_id",
                "customer_id": "@migration_customer_id",
                "exchange_rate": decimal_sql(payment["exchange_rate"], "1"),
                "base_amount": str(cents(allocation["amount"])),
                "currency_id": "@migration_currency_id",
            },
        )

    lines.extend(
        [
            "COMMIT;",
            "SELECT 'migration_complete' AS result, @migration_customer_id AS customer_id;",
            "",
        ]
    )
    output_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        output_flags |= os.O_NOFOLLOW
    try:
        output_fd = os.open(args.output, output_flags, 0o600)
    except FileExistsError:
        raise SystemExit(f"refusing to replace existing output: {args.output}") from None
    os.fchmod(output_fd, 0o600)
    with os.fdopen(output_fd, "w", encoding="utf-8") as output_file:
        output_file.write("\n".join(lines))
    print(f"active_clients={len(clients)}")
    print(f"active_invoices={len(invoices)}")
    print(f"invoice_items={item_count}")
    print(f"paid_invoices={paid_count}")
    print(f"partially_paid_invoices={partial_count}")
    print(f"unpaid_invoices={unpaid_count}")
    print(f"payments={len(allocations)}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
