"""Daily EUR total that fails to conform to its declared output schema.

The rollup itself is ordinary: group the declared read by day and sum the
amount. The last step is the deliberate mistake — the summed amount is cast to
a float before being returned, while the contract declares total_amount as
NUMERIC(12,2). The harness rejects float-to-decimal as a lossy cast rather than
letting pyarrow silently round to the target scale, so the node fails with a
ConformError naming the offending column.
"""
import pyarrow as pa
import pyarrow.compute as pc


def run(ctx):
    rows = ctx.read("daily")

    day = pc.cast(rows["created_at"], pa.date32())
    rows = rows.append_column("day", day)

    grouped = rows.group_by("day").aggregate([("amount_eur", "sum")])

    return pa.table(
        {
            "day": grouped.column("day"),
            "total_amount": pc.cast(grouped.column("amount_eur_sum"), pa.float64()),
        }
    )
