#!/bin/zsh
# Phone Calls (Beta) UI acceptance. Dedicated simulator only. Synthetic, loopback-only TLS fixtures; never samplehost.
#   scripts/fixtures/phone-two-logins-gateway.py  the Sessions gateway with two logins (account switching)
#   scripts/fixtures/fake-samplehost.py               a fake samplehost v2 API; the app's DEBUG build reaches it through the
#                                                 launch environment HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2
# The only key used is the synthetic KEYTEST.
#   zsh scripts/e2e-phone-simulation.sh <simulator udid> [gateway port, default 19978; fake samplehost uses port + 1]
#   HQ_PHONE_TEST=switch runs only the account-switch test; HQ_PHONE_DERIVED=<folder> reuses a DerivedData folder.
set -eu
cd "${0:A:h}/.."
SIM=${1:?pass a dedicated simulator UDID}
PORT=${2:-19978}
TPORT=$((PORT + 1))
OUT=${HQ_PHONE_ARTIFACTS:-$PWD/.build/phone-simulation}
DERIVED=${HQ_PHONE_DERIVED:-$OUT/DerivedData}
mkdir -p "$OUT/shots"; chmod 700 "$OUT"
for p in $PORT $TPORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then print -u2 "fixture port $p busy"; exit 1; fi
done
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$OUT/root.key" -out "$OUT/root.pem" -subj '/CN=HQ Phone Simulation Root' -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$OUT/server.key" -out "$OUT/server.csr" -subj '/CN=127.0.0.1' >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > "$OUT/server.ext"
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/root.pem" -CAkey "$OUT/root.key" -CAcreateserial -days 2 -extfile "$OUT/server.ext" -out "$OUT/server.pem" >/dev/null 2>&1
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl keychain "$SIM" add-root-cert "$OUT/root.pem"
rm -f "$OUT/credentials.json" "$OUT/credentials.json.b"
python3 scripts/fixtures/phone-two-logins-gateway.py --port "$PORT" --credentials "$OUT/credentials.json" --cert "$OUT/server.pem" --key "$OUT/server.key" > "$OUT/gateway.log" 2>&1 &
GPID=$!
python3 scripts/fixtures/fake-samplehost.py --port "$TPORT" --cert "$OUT/server.pem" --key "$OUT/server.key" > "$OUT/samplehost.log" 2>&1 &
TPID=$!
trap 'kill $GPID $TPID 2>/dev/null || true' EXIT INT TERM
for i in {1..100}; do
  [[ -s "$OUT/credentials.json" && -s "$OUT/credentials.json.b" ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$TPORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep .2
done
curl --fail --silent --cacert "$OUT/root.pem" "https://127.0.0.1:$TPORT/__fixture/state" > /dev/null
xcodegen generate -q
tests=(-only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsSimulatedAcceptance -only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsAccountSwitch)
if [[ ${HQ_PHONE_TEST:-} == switch ]]; then tests=(-only-testing:HermesHQNativeUITests/SessionsTests/testPhoneCallsAccountSwitch); fi
RESULT="$OUT/PhoneAcceptance-$(date +%Y%m%d-%H%M%S).xcresult"
set +e
TEST_RUNNER_HQN_UI_CREDENTIALS="$OUT/credentials.json" TEST_RUNNER_HQN_PHONE_B="$OUT/credentials.json.b" \
TEST_RUNNER_HQN_SAMPLEHOST_URL="https://127.0.0.1:$TPORT" TEST_RUNNER_HQN_SHOTS_DIR="$OUT/shots" \
 xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
 -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
 -parallel-testing-enabled NO -collect-test-diagnostics never "${tests[@]}" test > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
set -e
curl --fail --silent --cacert "$OUT/root.pem" "https://127.0.0.1:$TPORT/__fixture/state" > "$OUT/final-samplehost-state.json" || true
grep -E "Test Case .*(passed|failed)|Executed [0-9]+ test" "$OUT/xcodebuild.log" | sort -u || true
print "result bundle: $RESULT"
exit $STATUS
