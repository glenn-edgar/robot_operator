#!/bin/bash
# Pulls IRRIGATION_TIME_HISTORY (115 bins, each a list of up to ~30 runs)
# from the irrigation controller and writes JSON to ./data/.
#
# Each bin is keyed by concurrent-valve set, e.g.:
#   "satellite_1:12"                          → solo run
#   "satellite_1:12/satellite_1:39"           → two-valve concurrent run
# Each bin value: list[ run ]
# Each run: {WELL_PRESSURE, EQUIPMENT_CURRENT, IRRIGATION_CURRENT,
#            HUNTER_FLOW_METER, CLEANING_FLOW_METER, INPUT_PUMP_CURRENT,
#            OUTPUT_PUMP_CURRENT}
# Each measurement: {mean, sd, data: [s1..sN]}  (N varies per bin)
#
# Outputs:
#   data/time_history.json
#   data/time_history_fetched_at.txt
#   snapshots/YYYY-MM-DD/time_history.json

set -e
cd "$(dirname "$0")"
mkdir -p data

HASH_KEY='[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT][IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL][PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]'

ssh pi@irrigation "python3 - << PY
import redis, msgpack, json
r = redis.Redis(db=4)
h = r.hgetall('''$HASH_KEY''')
out = {k.decode(): msgpack.unpackb(v, raw=False) for k, v in h.items()}
print(json.dumps(out))
PY" > data/time_history.json

date -Iseconds > data/time_history_fetched_at.txt

TODAY=$(date +%Y-%m-%d)
mkdir -p snapshots/"$TODAY"
cp data/time_history.json            snapshots/"$TODAY"/time_history.json
cp data/time_history_fetched_at.txt  snapshots/"$TODAY"/time_history_fetched_at.txt
echo "fetched 115 bins -> $(pwd)/data/  (snapshot: snapshots/$TODAY/)"
