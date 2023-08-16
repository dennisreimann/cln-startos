#!/bin/sh

set -ea

_term() {
  echo "Caught SIGTERM signal!"
  kill -TERM "$lightningd_child" 2>/dev/null
  kill -TERM "$teosd_child" 2>/dev/null
  kill -TERM "$wtclient_child" 2>/dev/null
  kill -TERM "$wtserver_child" 2>/dev/null
}

_chld() {
  echo "Caught SIGCHLD signal!"
  kill -TERM "$lightningd_child" 2>/dev/null
  kill -TERM "$teosd_child" 2>/dev/null
  kill -TERM "$wtclient_child" 2>/dev/null
  kill -TERM "$wtserver_child" 2>/dev/null
  kill -TERM "$ui_child" 2>/dev/null
}

export EMBASSY_IP=$(ip -4 route list match 0/0 | awk '{print $3}')
export PEER_TOR_ADDRESS=$(yq e '.peer-tor-address' /root/.lightning/start9/config.yaml)
export RPC_TOR_ADDRESS=$(yq e '.rpc-tor-address' /root/.lightning/start9/config.yaml)
export REST_TOR_ADDRESS=$(yq e '.rest-tor-address' /root/.lightning/start9/config.yaml)
export WATCHTOWER_TOR_ADDRESS=$(yq e '.watchtower-tor-address' /root/.lightning/start9/config.yaml)
export TOWERS_DATA_DIR=/root/.lightning/.watchtower
export SPARKO_TOR_ADDRESS=$(yq e '.sparko-tor-address' /root/.lightning/start9/config.yaml)
export REST_LAN_ADDRESS=$(echo "$REST_TOR_ADDRESS" | sed 's/\.onion/\.local/')

mkdir -p $TOWERS_DATA_DIR

mkdir -p /root/.lightning/shared
mkdir -p /root/.lightning/public

echo $PEER_TOR_ADDRESS > /root/.lightning/start9/peerTorAddress
echo $RPC_TOR_ADDRESS > /root/.lightning/start9/rpcTorAddress
echo $REST_TOR_ADDRESS > /root/.lightning/start9/restTorAddress
echo $WATCHTOWER_TOR_ADDRESS > /root/.lightning/start9/watchtowerTorAddress
echo $SPARKO_TOR_ADDRESS > /root/.lightning/start9/sparkoTorAddress

sh /root/.lightning/start9/waitForStart.sh
sed "s/proxy={proxy}/proxy=${EMBASSY_IP}:9050/" /root/.lightning/config.main > /root/.lightning/config

echo "Cleaning old lightning rpc"
if [ -e /root/.lightning/bitcoin/lightning-rpc ]; then
    rm /root/.lightning/bitcoin/lightning-rpc
fi

# echo "Checking cert"
echo "Fetching system cert for REST interface"
# if ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/key.pem ] || ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/certificate.pem ]; then
  # echo "Cert missing, copying cert into c-lightning-REST dir"
while ! [ -e /mnt/cert/rest.key.pem ]; do
  echo "Waiting for system cert key file..."
  sleep 1
done
mkdir -p /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs
cp /mnt/cert/rest.key.pem /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/key.pem
while ! [ -e /mnt/cert/rest.cert.pem ]; do
  echo "Waiting for system cert..."
  sleep 1
done
cp /mnt/cert/rest.cert.pem /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/certificate.pem
# fi

# use macaroon if exists
if [ -e /root/.lightning/public/access.macaroon ] && [ -e /root/.lightning/public/rootKey.key ]; then
  cp /root/.lightning/public/access.macaroon /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon
  cp /root/.lightning/public/rootKey.key /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key
else
  echo "Macaroon not found, generating new one"
fi

echo "Starting lightningd"
lightningd --database-upgrade=true$MIN_ONCHAIN$AUTO_CLOSE$ZEROBASEFEE$MIN_CHANNEL$MAX_CHANNEL &
lightningd_child=$!

if [ "$(yq ".watchtowers.wt-server" /root/.lightning/start9/config.yaml)" = "true" ]; then
  echo "Starting teosd"
  teosd --datadir=/root/.lightning/.teos &
  teosd_child=$!
fi

while ! [ -e /root/.lightning/bitcoin/lightning-rpc ]; do
    echo "Waiting for lightning rpc to start..."
    sleep 30
    if ! ps -p $lightningd_child > /dev/null; then
        echo "lightningd has stopped, exiting container"
        exit 1
    fi
done

echo "Cleaning link to lightning rpc"
if [ -e /root/.lightning/shared/lightning-rpc ]; then
    rm /root/.lightning/shared/lightning-rpc
fi
ln /root/.lightning/bitcoin/lightning-rpc /root/.lightning/shared/lightning-rpc


if ! [ -e /root/.lightning/public/access.macaroon ] || ! [ -e /root/.lightning/public/rootKey.key ] ; then
  while ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon ] || ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key ];
  do
      echo "Waiting for macaroon..."
      sleep 1
      if ! ps -p $lightningd_child > /dev/null; then
          echo "lightningd has stopped, exiting container"
          exit 1
      fi
  done
  cp /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon /root/.lightning/public/access.macaroon
  cp /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key /root/.lightning/public/rootKey.key
fi

cat /root/.lightning/public/access.macaroon | basenc --base64url -w0  > /root/.lightning/start9/access.macaroon.base64
cat /root/.lightning/public/access.macaroon | basenc --base16 -w0  > /root/.lightning/start9/access.macaroon.hex

lightning-cli getinfo > /root/.lightning/start9/lightningGetInfo

if [ "$(yq ".watchtowers.wt-client" /root/.lightning/start9/config.yaml)" = "true" ]; then
  lightning-cli listtowers > /root/.lightning/start9/wtClientInfo
  cat /root/.lightning/start9/wtClientInfo | jq -r 'to_entries[] | .key + "@" + (.value.net_addr | split("://")[1])' > /root/.lightning/start9/wt_old
  cat /root/.lightning/start9/config.yaml | yq '.watchtowers.add-watchtowers | .[]' > /root/.lightning/start9/wt_new
  echo "Abandoning old watchtowers"
  grep -Fxvf /root/.lightning/start9/wt_new /root/.lightning/start9/wt_old | cut -f1 -d "@" | xargs -I{} lightning-cli abandontower {} 2>&1 || true
  echo "Regsistering new watchtowers"
  grep -Fxvf /root/.lightning/start9/wt_old /root/.lightning/start9/wt_new | xargs -I{} lightning-cli registertower {} 2>&1 || true

  while true; do lightning-cli listtowers > /root/.lightning/start9/wtClientInfo || echo 'Failed to fetch towers from client endpoint.'; sleep 60; done &
  wtclient_child=$!
fi

if [ "$(yq ".watchtowers.wt-server" /root/.lightning/start9/config.yaml)" = "true" ]; then
  while true; do teos-cli --datadir=/root/.lightning/.teos gettowerinfo > /root/.lightning/start9/teosTowerInfo 2>/dev/null || echo 'Failed to fetch tower properties, tower still starting.'; sleep 30; done &
  wtserver_child=$!
fi

# User Interface
export APP_CORE_LIGHTNING_DAEMON_IP="localhost"
export LIGHTNING_REST_IP="localhost"
export APP_CORE_LIGHTNING_IP="0.0.0.0"
export APP_CONFIG_DIR="$/root/.lightning/data/app"
export APP_CORE_LIGHTNING_REST_PORT=3001
export APP_CORE_LIGHTNING_REST_CERT_DIR="/usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs"
export DEVICE_DOMAIN_NAME=$RPC_LAN_ADDRESS
export LOCAL_HOST=$REST_LAN_ADDRESS
export APP_CORE_LIGHTNING_COMMANDO_ENV_DIR="/root/.lightning"
export APP_CORE_LIGHTNING_REST_HIDDEN_SERVICE=$REST_TOR_ADDRESS
export APP_CORE_LIGHTNING_WEBSOCKET_PORT=4269
export COMMANDO_CONFIG="/root/.lightning/.commando-env"
export APP_CORE_LIGHTNING_PORT=4500
export APP_MODE=production

EXISTING_PUBKEY=""
GETINFO_RESPONSE=""
LIGHTNINGD_PATH=$APP_CORE_LIGHTNING_COMMANDO_ENV_DIR"/"
LIGHTNING_RPC="/root/.lightning/bitcoin/lightning-rpc"
ENV_FILE_PATH="$LIGHTNINGD_PATH"".commando-env"

echo "$LIGHTNING_RPC"

getinfo_request() {
  cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "getinfo",
  "params": []
}
EOF
}

commando_rune_request() {
  cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "commando-rune",
  "params": [null, [["For Application#"]]]
}
EOF
}

commando_datastore_request() {
  cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "datastore",
  "params": [["commando", "runes", "$UNIQUE_ID"], "$RUNE"]
}
EOF
}

generate_new_rune() {
  COUNTER=0
  RUNE=""
  while { [ "$RUNE" = "" ] || [ "$RUNE" = "null" ]; } && [ $COUNTER -lt 10 ]; do
    # Send 'commando-rune' request
    echo "Generating rune attempt: $COUNTER"
    COUNTER=$((COUNTER+1))

    RUNE_RESPONSE=$( (echo "$(commando_rune_request)"; sleep 2) | socat - UNIX-CONNECT:"$LIGHTNING_RPC")

    RUNE=$(echo "$RUNE_RESPONSE" | jq -r '.result.rune')
    UNIQUE_ID=$(echo "$RUNE_RESPONSE" | jq -r '.result.unique_id')
    echo "RUNE_RESPONSE"
    echo "$RUNE_RESPONSE"
    echo "RUNE"
    echo "$RUNE"

    if [ "$RUNE" != "" ] && [ "$RUNE" != "null" ]; then
      # Save rune in env file
      echo "LIGHTNING_RUNE=\"$RUNE\"" >> "$COMMANDO_CONFIG"
    fi

    if [ "$UNIQUE_ID" != "" ] &&  [ "$UNIQUE_ID" != "null" ]; then
      # This will fail for v>23.05
      DATASTORE_RESPONSE=$( (echo "$(commando_datastore_request)"; sleep 1) | socat - UNIX-CONNECT:"$LIGHTNING_RPC") > /dev/null
    fi
  done
  if [ $COUNTER -eq 10 ] && [ "$RUNE" = "" ]; then
    echo "Error: Unable to generate rune for application authentication!"
  fi
}

# Read existing pubkey
if [ -f "$COMMANDO_CONFIG" ]; then
  EXISTING_PUBKEY=$(head -n1 "$COMMANDO_CONFIG")
  EXISTING_RUNE=$(sed -n "2p" "$COMMANDO_CONFIG")
  echo "EXISTING_PUBKEY"
  echo "$EXISTING_PUBKEY"
  echo "EXISTING_RUNE"
  echo "$EXISTING_RUNE"
fi

# Getinfo from CLN
until [ "$GETINFO_RESPONSE" != "" ]
do
  echo "Waiting for lightningd"
  # Send 'getinfo' request
  GETINFO_RESPONSE=$( (echo "$(getinfo_request)"; sleep 1) | socat - UNIX-CONNECT:"$LIGHTNING_RPC")
  echo "$GETINFO_RESPONSE"
done
# Write 'id' from the response as pubkey
LIGHTNING_PUBKEY="$(jq -n "$GETINFO_RESPONSE" | jq -r '.result.id')"
echo "$LIGHTNING_PUBKEY"

# Compare existing pubkey with current
if [ "$EXISTING_PUBKEY" != "LIGHTNING_PUBKEY=\"$LIGHTNING_PUBKEY\"" ] ||
  [ "$EXISTING_RUNE" = "" ] || 
  [ "$EXISTING_RUNE" = "LIGHTNING_RUNE=\"\"" ] ||
  [ "$EXISTING_RUNE" = "LIGHTNING_RUNE=\"null\"" ]; then
  # Pubkey changed or missing rune; rewrite new data on the file.
  echo "Pubkey mismatched or missing rune; Rewriting the data."
  cat /dev/null > "$COMMANDO_CONFIG"
  echo "LIGHTNING_PUBKEY=\"$LIGHTNING_PUBKEY\"" >> "$COMMANDO_CONFIG"
  generate_new_rune
else
  echo "Pubkey matches with existing pubkey."
fi

npm run start &
ui_child=$!

echo "All configuration Done"

trap _term TERM
trap _chld CHLD

wait $lightningd_child $teosd_child $wtclient_child $wtserver_child $ui_child
