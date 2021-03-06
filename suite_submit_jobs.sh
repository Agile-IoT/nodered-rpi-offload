#!/usr/bin/env bash
# Configure conf.sh first:
#
# Prerequisites:
# - docker-compose, gnuplot, jq (https://stedolan.github.io/jq/download/), bc, imagemagick
# - performance-monitor
#   performance-monitor must be configured ($PERF_DIR/src/conf) to
#   reach the docker daemon and to watch the "nodered" container.
# - images generated by performance-monitor are under $PERF_DIR/img
# - DATA_ROOT_DIR exists
# - take_results assumes that `ssh $PI_HOST` succeeds
#   (modify ~/.ssh/config if needed)
# - there are no files in /tmp/offload in the gateway
set -u
set -e

source conf.sh

if [ $# -lt 2 ]; then
  echo "Usage: $0 [-m <metric> <value>] <paralleljobs> <totaljobs> [<suffix>]"
  echo "  Send totaljobs to nodered with a maximum of paralleljobs to be processed in parallel"
  echo "  If -m is supplied, jobs are sent while metric (e.g. 'temp') is below value "
  echo "Usage: $0 <period> <totaljobs> <threshold-key> <threshold-value> [<suffix>]"
  echo "  Send totaljobs to nodered each period seconds, offloading when threshold-key is above treshold-value"
  echo "  threshold-key is one of {cpu, mem, temp, maxlocal}"
  echo "  suffix defaults to 1"
  exit 1
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ $1 = "-m" ]; then
    MEASURE=$2
    MEASURE_VALUE=$3
    shift 3
    WAIT="wait-$MEASURE-$MEASURE_VALUE-"
fi

TOTAL=$2
if [ $# -le 3 ]; then
    MODE="jobsn"
    PARALLEL=$1
    SUFFIX=${3:-1}
    DATA_DIR="$DATA_ROOT_DIR"/$PARALLEL-$TOTAL-${WAIT:-}$SUFFIX
else
    MODE="jobst"
    PERIOD=$1
    KEY=$3
    VALUE=$4
    SUFFIX=${5:-1}
    DATA_DIR="$DATA_ROOT_DIR"/$PERIOD-$TOTAL-$KEY-$VALUE-$SUFFIX
fi

if [ -d "$DATA_DIR" ]; then
  echo "folder already exists, skipping"
  exit 0
fi

set -x

cd "$DIR/$ARCH"
docker-compose down || echo "already down"
docker-compose up -d

docker-compose logs > /tmp/node-red.log 2>&1 &
sleep 10

cd $PERF_DIR
node src/index.js &>/tmp/performance-monitor.log &
PERF_PID=$!

echo "performance-monitor PID=$PERF_PID"

sleep 5

cd $DIR

if [ "$MODE" == "jobsn" ]; then
    ./submit_jobsn.sh $PARALLEL $TOTAL ${MEASURE:-} ${MEASURE_VALUE:-}
else
    ./submit_jobst.sh $PERIOD $TOTAL $KEY $VALUE
fi

sleep 5

kill -SIGINT $PERF_PID

cd "$DIR/$ARCH" && docker-compose down

cd $DIR
./take_results.sh "$DATA_DIR"

set +e          # temporal set -e disable
ps $PERF_PID
while [ $? -eq 0 ]; do
    sleep 1
    ps $PERF_PID
done
set -e

mv $PERF_DIR/img/* "$DATA_DIR"

cd "$DATA_DIR"

"$DIR"/graphs/process.sh monitor.json *total*.json

set +x
