#!/bin/bash
# Pulls IRRIGATION_VALVE_TEST + valve_group_assignments.json from the
# irrigation controller via SSH and writes them as JSON to ./data/.
#
# Run from this directory:  ./fetch_data.sh
#
# Outputs:
#   data/valve_test.json            — {valve_id: [I_amps, ...]} for 49 valves
#   data/valve_groups.json          — sun-exposure cohorts (sat_1/2/3 only)
#   data/fetched_at.txt             — ISO timestamp of pull

set -e
cd "$(dirname "$0")"
mkdir -p data

HASH_KEY='[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT][IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL][PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_VALVE_TEST]'

ssh pi@irrigation "python3 - << PY
import redis, msgpack, json
r = redis.Redis(db=4)
h = r.hgetall('''$HASH_KEY''')
out = {k.decode(): msgpack.unpackb(v, raw=False) for k, v in h.items()}
print(json.dumps(out))
PY" > data/valve_test.json

scp -q pi@irrigation:/home/pi/nano_data_center/code/system_data_files/valve_group_assignments.json data/valve_groups.json

date -Iseconds > data/fetched_at.txt

# Archive to dated snapshot for day-over-day comparison.
TODAY=$(date +%Y-%m-%d)
mkdir -p snapshots/"$TODAY"
cp data/valve_test.json   snapshots/"$TODAY"/valve_test.json
cp data/valve_groups.json snapshots/"$TODAY"/valve_groups.json
cp data/fetched_at.txt    snapshots/"$TODAY"/fetched_at.txt
echo "fetched 49 valves + groups -> $(pwd)/data/  (snapshot: snapshots/$TODAY/)"
