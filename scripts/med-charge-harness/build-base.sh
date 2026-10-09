#!/bin/sh
# Builds the medcharge_base template the browser harness clones: the med
# fixture, the med migration, the direct-charge fixture, the direct-charge
# migration and the office-reversal migration, each run as it ships.
# Local PostgreSQL 16 only.
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); chmod 755 "$W"
cp "$R/docs/sql/tests/2026-10-01_med_inventory_fixture.sql" "$R/docs/sql/2026-10-01_med_inventory.sql" \
   "$R/docs/sql/tests/2026-10-07_med_direct_charge_fixture.sql" "$R/docs/sql/2026-10-07_med_direct_charge.sql" \
   "$R/docs/sql/2026-10-09c_med_office_reversal.sql" "$W/"
chmod 644 "$W"/*.sql
su postgres -c "dropdb --if-exists medcharge_base && createdb medcharge_base"
for f in 2026-10-01_med_inventory_fixture.sql 2026-10-01_med_inventory.sql \
         2026-10-07_med_direct_charge_fixture.sql 2026-10-07_med_direct_charge.sql \
         2026-10-09c_med_office_reversal.sql; do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -d medcharge_base -f $W/$f" >/dev/null
done
rm -rf "$W"
echo "medcharge_base built"
