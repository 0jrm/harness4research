#!/usr/bin/env bash
# usage: relay.sh <port> <unix socket>
# Keeps driver/netrelay.py serving inside the sandbox for the whole episode. The agent shares the sandbox, and an agent
# that cleans up its own scripts with pkill -f python3 would kill a relay started as python3: in a pilot one did, and
# the client lost its model for the rest of the episode. So no process of the relay has python3 in its command line,
# and a relay killed by name, as killall python3 does, is back within half a second.
while :; do
  (exec -a model-relay python3 -I /opt/model/netrelay.py "$@")
  sleep 0.5
done
