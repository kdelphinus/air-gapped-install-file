#!/bin/bash
# ------------------------------------------------------------------
# Kafka v3.9.0 Offline Installer Virtual Dry-run Simulator
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KAFKA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_BIN_DIR="$SCRIPT_DIR/mock_bin"

echo "=== Kafka v3.9.0 Virtual Test Environment Setup ==="
mkdir -p "$MOCK_BIN_DIR"
mkdir -p "$SCRIPT_DIR/captured"

# 1. Write mock kubectl
cat > "$MOCK_BIN_DIR/kubectl" <<'EOF'
#!/bin/bash
CMD_ARGS="$*"
if [[ "$CMD_ARGS" == *"get nodes -o wide"* ]]; then
  echo -e "NAME\tSTATUS\tROLES\tAGE\tVERSION\tINTERNAL-IP\tOS-IMAGE\tKERNEL-VERSION\tCONTAINER-RUNTIME"
  echo -e "node-0\tReady\tcontrol-plane,worker\t10d\tv1.30.0\t192.168.1.100\tRocky Linux\t...\tcontainerd://1.7"
  echo -e "node-1\tReady\tworker\t10d\tv1.30.0\t192.168.1.101\tRocky Linux\t...\tcontainerd://1.7"
  echo -e "node-2\tReady\tworker\t10d\tv1.30.0\t192.168.1.102\tRocky Linux\t...\tcontainerd://1.7"
  exit 0
elif [[ "$CMD_ARGS" == *"get ns kafka"* ]]; then
  # Assume namespace does not exist initially
  exit 1
elif [[ "$CMD_ARGS" == *"apply -f -"* ]]; then
  SCENARIO_NAME="${CURRENT_SCENARIO:-unknown}"
  OUTPUT_FILE="${CAPTURED_DIR:-.}/pv_${SCENARIO_NAME}.yaml"
  echo ">>> [MOCK kubectl] Capturing PV manifest to $OUTPUT_FILE"
  cat > "$OUTPUT_FILE"
  exit 0
else
  echo "[MOCK kubectl] Executed: kubectl $CMD_ARGS"
  exit 0
fi
EOF
chmod +x "$MOCK_BIN_DIR/kubectl"

# 2. Write mock helm
cat > "$MOCK_BIN_DIR/helm" <<'EOF'
#!/bin/bash
CMD_ARGS="$*"
SCENARIO_NAME="${CURRENT_SCENARIO:-unknown}"
VALUES_CAPTURE_FILE="${CAPTURED_DIR:-.}/values_${SCENARIO_NAME}.yaml"

if [[ "$CMD_ARGS" == *"status kafka"* ]]; then
  # Return non-zero to simulate no chart installed yet
  exit 1
elif [[ "$CMD_ARGS" == *"upgrade --install"* ]]; then
  echo ">>> [MOCK helm] Capturing values-custom.yaml to $VALUES_CAPTURE_FILE"
  if [ -f "./values-custom.yaml" ]; then
    cp "./values-custom.yaml" "$VALUES_CAPTURE_FILE"
  else
    echo "WARNING: ./values-custom.yaml not found to copy!"
  fi
  echo "[MOCK helm] Executed: helm $CMD_ARGS"
  exit 0
else
  echo "[MOCK helm] Executed: helm $CMD_ARGS"
  exit 0
fi
EOF
chmod +x "$MOCK_BIN_DIR/helm"

# 3. Write mock docker
cat > "$MOCK_BIN_DIR/docker" <<'EOF'
#!/bin/bash
echo "[MOCK docker] Executed: docker $*"
exit 0
EOF
chmod +x "$MOCK_BIN_DIR/docker"

# 4. Write mock ctr
cat > "$MOCK_BIN_DIR/ctr" <<'EOF'
#!/bin/bash
echo "[MOCK ctr] Executed: ctr $*"
exit 0
EOF
chmod +x "$MOCK_BIN_DIR/ctr"

# 5. Write mock sudo
cat > "$MOCK_BIN_DIR/sudo" <<'EOF'
#!/bin/bash
if [ "$1" == "ctr" ]; then
  shift
  exec ctr "$@"
else
  exec "$@"
fi
EOF
chmod +x "$MOCK_BIN_DIR/sudo"

# Export MOCK PATH
export PATH="$MOCK_BIN_DIR:$PATH"
export CAPTURED_DIR="$SCRIPT_DIR/captured"

# Helper function to clean up workspace state before test
reset_state() {
  rm -f "$KAFKA_DIR/install.conf"
  rm -f "$KAFKA_DIR/values-custom.yaml"
}

run_scenario() {
  local SCENARIO_ID=$1
  local TITLE=$2
  local INPUTS=$3

  echo -e "\n=================================================================="
  echo -e "🧪 Running Scenario $SCENARIO_ID: $TITLE"
  echo -e "=================================================================="
  
  reset_state
  export CURRENT_SCENARIO="$SCENARIO_ID"

  # Run install.sh feeding interactive inputs
  echo "$INPUTS" | "$KAFKA_DIR/scripts/install.sh"

  # Validate generated configs
  echo -e "\n📋 [Result Verification - Scenario $SCENARIO_ID]"
  if [ -f "$KAFKA_DIR/install.conf" ]; then
    echo "✅ install.conf was created:"
    cat "$KAFKA_DIR/install.conf"
    # Copy install.conf for scenario verification
    cp "$KAFKA_DIR/install.conf" "$CAPTURED_DIR/install_${SCENARIO_ID}.conf"
    # Load config variables into the test shell
    source "$KAFKA_DIR/install.conf"
  else
    echo "❌ Error: install.conf was NOT created!"
  fi

  if [ "${STORAGE_TYPE:-}" != "nfs-dynamic" ] && [ -f "$KAFKA_DIR/values-custom.yaml" ]; then
    echo "✅ values-custom.yaml was correctly preserved in workspace root."
  fi

  if [ -f "$CAPTURED_DIR/values_${SCENARIO_ID}.yaml" ]; then
    echo "✅ Captured values_${SCENARIO_ID}.yaml (tail 15 lines):"
    tail -n 15 "$CAPTURED_DIR/values_${SCENARIO_ID}.yaml"
  else
    echo "❌ Error: values-custom.yaml was NOT captured by helm mock!"
  fi

  if [ -f "$CAPTURED_DIR/pv_${SCENARIO_ID}.yaml" ]; then
    echo "✅ Captured pv_${SCENARIO_ID}.yaml (first 10 lines):"
    head -n 10 "$CAPTURED_DIR/pv_${SCENARIO_ID}.yaml"
  else
    echo "ℹ️  No static PV manifest was applied (expected for Dynamic SC)."
  fi
}

# ==================================================================
# Scenario A: Harbor + Dynamic StorageClass (nfs-client)
# ==================================================================
# Inputs:
# 1) Harbor (Option 1) -> Registry: 192.168.1.10:30002 -> Project: library
# 2) Dynamic (Option 3) -> SC: nfs-client
run_scenario "A" "Harbor Registry + Dynamic StorageClass" \
"1
192.168.1.10:30002
library
3
nfs-client"

# ==================================================================
# Scenario B: Local Images + HostPath (Single Node Mode)
# ==================================================================
# Inputs:
# 1) Local (Option 2)
# 2) HostPath (Option 1) -> Single Node (Option 1) -> Node: node-1 -> Path: /var/lib/kafka-single
run_scenario "B" "Local Images + HostPath Single Node" \
"2
1
1
node-1
/var/lib/kafka-single"

# ==================================================================
# Scenario C: Local Images + HostPath (Multi-Node HA Mode)
# ==================================================================
# Inputs:
# 1) Local (Option 2)
# 2) HostPath (Option 1) -> Multi Node (Option 2) -> node-0 -> node-1 -> node-2 -> Path: /var/lib/kafka-multi
run_scenario "C" "Local Images + HostPath Multi-Node HA" \
"2
1
2
node-0
node-1
node-2
/var/lib/kafka-multi"

# ==================================================================
# Scenario D: Harbor + NAS (NFS Static PV)
# ==================================================================
# Inputs:
# 1) Harbor (Option 1) -> Registry: 10.0.0.5:30002 -> Project: myproject
# 2) NAS (Option 2) -> NFS Server: 10.0.0.10 -> NFS Path: /nfs/kafka-data
run_scenario "D" "Harbor Registry + Static NAS (NFS)" \
"1
10.0.0.5:30002
myproject
2
10.0.0.10
/nfs/kafka-data"

echo -e "\n🎉 All scenarios simulated successfully! Output saved in $CAPTURED_DIR."
reset_state
