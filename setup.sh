#!/bin/bash
set -euo pipefail

# ============================================================
# WeatherWise Agent Demo - Setup Script
# ============================================================
# This script sets up all dependencies and deploys the agent:
#   1. Creates catalog, schema, volume, and Delta tables
#   2. Creates UC SQL functions (get_shipments, get_supplier_details, etc.)
#   3. Creates Vector Search endpoint and index
#   4. Logs, registers, and deploys the agent to Model Serving
#
# Usage:
#   ./setup.sh                         # Auto-detect cluster or fall back to manual
#   ./setup.sh --cluster-id <id>       # Use a specific cluster
#   ./setup.sh --manual                # Just import notebooks, print instructions
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_SETUP_PATH=""
CLUSTER_ID=""
MANUAL_MODE=false

# ── Parse arguments ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id)
      CLUSTER_ID="$2"
      shift 2
      ;;
    --manual)
      MANUAL_MODE=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: ./setup.sh [--cluster-id <id>] [--manual]"
      exit 1
      ;;
  esac
done

# ── Load environment variables ───────────────────────────────
load_env() {
  local env_file=""
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    env_file="$SCRIPT_DIR/.env"
  elif [[ -f "$SCRIPT_DIR/_env" ]]; then
    env_file="$SCRIPT_DIR/_env"
  else
    echo "ERROR: No .env or _env file found in $SCRIPT_DIR"
    echo "Copy _env to .env and fill in your values first."
    exit 1
  fi

  echo "Loading environment from $env_file"
  # Source env file, stripping comments and empty lines
  set -a
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    eval "$line" 2>/dev/null || true
  done < "$env_file"
  set +a

  # Validate required variables
  for var in TARGET_CATALOG TARGET_SCHEMA VS_INDEX_BASE_TABLE VS_INDEX AGENT_NAME; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required variable $var is not set in $env_file"
      exit 1
    fi
  done

  if [[ -z "${AI_GATEWAY_MODEL:-}" ]]; then
    echo "ERROR: Required variable AI_GATEWAY_MODEL is not set in $env_file"
    exit 1
  fi

  echo "  TARGET_CATALOG=$TARGET_CATALOG"
  echo "  TARGET_SCHEMA=$TARGET_SCHEMA"
  echo "  VS_INDEX_BASE_TABLE=$VS_INDEX_BASE_TABLE"
  echo "  VS_INDEX=$VS_INDEX"
  echo "  AI_GATEWAY_MODEL=$AI_GATEWAY_MODEL"
}

# ── Validate prerequisites ───────────────────────────────────
check_prerequisites() {
  echo ""
  echo "Checking prerequisites..."

  if ! command -v databricks &>/dev/null; then
    echo "ERROR: Databricks CLI not found. Install it first:"
    echo "  brew install databricks"
    exit 1
  fi
  echo "  Databricks CLI: OK"

  if ! databricks auth describe &>/dev/null; then
    echo "ERROR: Databricks CLI not authenticated. Run:"
    echo "  databricks auth login"
    exit 1
  fi

  local user
  user=$(databricks current-user me 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['userName'])" 2>/dev/null || echo "")
  if [[ -z "$user" ]]; then
    echo "ERROR: Could not determine current user. Check your Databricks auth."
    exit 1
  fi
  echo "  Authenticated as: $user"

  WORKSPACE_SETUP_PATH="/Workspace/Users/$user/weatherwise_setup"
}

# ── Find or validate cluster ─────────────────────────────────
resolve_cluster() {
  if [[ "$MANUAL_MODE" == "true" ]]; then
    return
  fi

  if [[ -n "$CLUSTER_ID" ]]; then
    echo ""
    echo "Validating cluster $CLUSTER_ID..."
    local state
    state=$(databricks clusters get "$CLUSTER_ID" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))" 2>/dev/null || echo "ERROR")
    if [[ "$state" == "ERROR" ]]; then
      echo "ERROR: Could not find cluster $CLUSTER_ID"
      exit 1
    fi
    echo "  Cluster state: $state"
    if [[ "$state" == "TERMINATED" ]]; then
      echo "  Starting cluster..."
      databricks clusters start "$CLUSTER_ID" 2>/dev/null
      echo "  Waiting for cluster to start..."
      while true; do
        state=$(databricks clusters get "$CLUSTER_ID" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
        if [[ "$state" == "RUNNING" ]]; then
          echo "  Cluster is running."
          break
        elif [[ "$state" == "ERROR" || "$state" == "UNKNOWN" ]]; then
          echo "  ERROR: Cluster failed to start (state: $state)"
          exit 1
        fi
        sleep 10
      done
    fi
    return
  fi

  # Auto-detect: find a running cluster
  echo ""
  echo "Looking for a running cluster..."
  CLUSTER_ID=$(databricks clusters list --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
clusters = data if isinstance(data, list) else data.get('clusters', [])
for c in clusters:
    if c.get('state') == 'RUNNING' and c.get('cluster_source') != 'JOB':
        print(c['cluster_id'])
        break
" 2>/dev/null || echo "")

  if [[ -n "$CLUSTER_ID" ]]; then
    local name
    name=$(databricks clusters get "$CLUSTER_ID" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('cluster_name',''))" 2>/dev/null || echo "")
    echo "  Found running cluster: $name ($CLUSTER_ID)"
  else
    echo "  No running cluster found."
    echo "  Will fall back to manual instructions."
    MANUAL_MODE=true
  fi
}

# ── Upload a file to workspace (as a file, not notebook) ─────
upload_workspace_file() {
  local ws_path="$1"
  local local_path="$2"
  # Delete any existing notebook with the same name (stored without .py extension)
  local ws_path_no_ext="${ws_path%.py}"
  databricks workspace delete "$ws_path_no_ext" 2>/dev/null || true
  databricks workspace delete "$ws_path" 2>/dev/null || true
  # Use the REST API with RAW format — the CLI's --format RAW still creates notebooks for .py
  databricks api post /api/2.0/workspace/import --json "{
    \"path\": \"$ws_path\",
    \"format\": \"RAW\",
    \"content\": \"$(base64 < "$local_path")\",
    \"overwrite\": true
  }" >/dev/null 2>&1
}

# ── Import notebooks to workspace ────────────────────────────
import_notebooks() {
  echo ""
  echo "Importing notebooks to $WORKSPACE_SETUP_PATH..."

  databricks workspace mkdirs "$WORKSPACE_SETUP_PATH" 2>/dev/null || true

  # Import setup_data notebook
  echo "  Importing setup_data..."
  databricks workspace import "$WORKSPACE_SETUP_PATH/setup_data" \
    --file "$SCRIPT_DIR/data/setup_data.ipynb" \
    --format JUPYTER \
    --language PYTHON \
    --overwrite 2>/dev/null

  # Import UC functions notebook
  echo "  Importing tool_uc_functions..."
  databricks workspace import "$WORKSPACE_SETUP_PATH/tool_uc_functions" \
    --file "$SCRIPT_DIR/agent_src/tools/uc_tools/tool_uc_functions.ipynb" \
    --format JUPYTER \
    --language PYTHON \
    --overwrite 2>/dev/null

  # Import agent_eval_notebook and its dependencies (agent code + tools)
  echo "  Importing agent_eval_notebook..."
  databricks workspace import "$WORKSPACE_SETUP_PATH/agent_eval_notebook" \
    --file "$SCRIPT_DIR/agent_src/agent_eval_notebook.ipynb" \
    --format JUPYTER \
    --language PYTHON \
    --overwrite 2>/dev/null

  echo "  Uploading agent source code as workspace files..."
  # Must upload as files (not notebooks) so Python can import them
  upload_workspace_file "$WORKSPACE_SETUP_PATH/weatherwise_agent.py" "$SCRIPT_DIR/agent_src/weatherwise_agent.py"

  # Upload custom tools as files
  databricks workspace mkdirs "$WORKSPACE_SETUP_PATH/tools/custom_tools" 2>/dev/null || true
  for tool_file in "$SCRIPT_DIR/agent_src/tools/custom_tools/"*.py; do
    local fname=$(basename "$tool_file")
    upload_workspace_file "$WORKSPACE_SETUP_PATH/tools/custom_tools/$fname" "$tool_file"
  done

  # Upload .env file so notebooks can read it
  echo "  Uploading .env..."
  local env_file="$SCRIPT_DIR/.env"
  [[ ! -f "$env_file" ]] && env_file="$SCRIPT_DIR/_env"
  databricks workspace import "$WORKSPACE_SETUP_PATH/.env" \
    --file "$env_file" \
    --format AUTO \
    --overwrite 2>/dev/null || true

  # Upload CSV data files
  echo "  Uploading CSV data files..."
  for csv in "$SCRIPT_DIR/data/"*.csv; do
    local fname=$(basename "$csv")
    databricks workspace import "$WORKSPACE_SETUP_PATH/$fname" \
      --file "$csv" \
      --format AUTO \
      --overwrite 2>/dev/null || true
  done

  echo "  Notebooks imported successfully."
}

# ── Run a notebook as a one-time job ─────────────────────────
run_notebook() {
  local notebook_path="$1"
  local notebook_name="$2"
  local params="$3"

  echo ""
  echo "Running $notebook_name..."

  local run_id
  run_id=$(databricks jobs submit --no-wait --json "{
    \"run_name\": \"weatherwise_setup_${notebook_name}\",
    \"tasks\": [
      {
        \"task_key\": \"${notebook_name}\",
        \"existing_cluster_id\": \"$CLUSTER_ID\",
        \"notebook_task\": {
          \"notebook_path\": \"$notebook_path\",
          \"base_parameters\": $params
        }
      }
    ]
  }" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['run_id'])" 2>/dev/null)

  if [[ -z "$run_id" ]]; then
    echo "  ERROR: Failed to submit job for $notebook_name"
    return 1
  fi

  echo "  Submitted run $run_id. Waiting for completion..."

  # Poll for completion
  local state="PENDING"
  local last_state=""
  while true; do
    state=$(databricks jobs get-run "$run_id" --output json 2>/dev/null | python3 -c "
import sys, json
run = json.load(sys.stdin)
state = run.get('state', {})
life_cycle = state.get('life_cycle_state', 'UNKNOWN')
result = state.get('result_state', '')
if life_cycle in ('TERMINATED', 'SKIPPED', 'INTERNAL_ERROR'):
    print(f'{life_cycle}:{result}')
else:
    print(life_cycle)
" 2>/dev/null || echo "UNKNOWN")

    if [[ "$state" != "$last_state" ]]; then
      echo "  Status: $state"
      last_state="$state"
    fi

    case "$state" in
      TERMINATED:SUCCESS)
        echo "  $notebook_name completed successfully!"
        return 0
        ;;
      TERMINATED:FAILED|TERMINATED:TIMEDOUT|TERMINATED:CANCELED|SKIPPED*|INTERNAL_ERROR*)
        echo "  ERROR: $notebook_name failed with state: $state"
        echo "  Check the run at: $(databricks jobs get-run "$run_id" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('run_page_url',''))" 2>/dev/null)"
        return 1
        ;;
    esac

    sleep 10
  done
}

# ── Create vector search index via API ───────────────────────
create_vector_search_index() {
  local index_name="$TARGET_CATALOG.$TARGET_SCHEMA.$VS_INDEX"
  local source_table="$TARGET_CATALOG.$TARGET_SCHEMA.$VS_INDEX_BASE_TABLE"
  local endpoint_name="$TARGET_CATALOG"

  echo ""
  echo "Checking vector search index: $index_name..."

  # Check if index already exists
  local existing
  existing=$(databricks api get "/api/2.0/vector-search/indexes/$index_name" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

  if [[ "$existing" == "$index_name" ]]; then
    echo "  Vector search index already exists. Skipping."
    return 0
  fi

  echo "  Creating vector search index..."
  databricks api post /api/2.0/vector-search/indexes --json "{
    \"name\": \"$index_name\",
    \"endpoint_name\": \"$endpoint_name\",
    \"primary_key\": \"product_id\",
    \"index_type\": \"DELTA_SYNC\",
    \"delta_sync_index_spec\": {
      \"source_table\": \"$source_table\",
      \"pipeline_type\": \"TRIGGERED\",
      \"embedding_source_columns\": [
        {
          \"name\": \"product_doc\",
          \"embedding_model_endpoint_name\": \"databricks-gte-large-en\"
        }
      ]
    }
  }" 2>/dev/null

  echo "  Vector search index creation initiated."
  echo "  Note: Index sync may take a few minutes to complete."
}

# ── Print manual instructions ────────────────────────────────
print_manual_instructions() {
  echo ""
  echo "============================================================"
  echo "  MANUAL SETUP INSTRUCTIONS"
  echo "============================================================"
  echo ""
  echo "Notebooks have been imported to your workspace at:"
  echo "  $WORKSPACE_SETUP_PATH"
  echo ""
  echo "Run them in this order on a cluster with the Databricks Runtime:"
  echo ""
  echo "  1. setup_data"
  echo "     - Creates schema, volume, Delta tables, and vector search endpoint"
  echo "     - Parameters: TARGET_CATALOG=$TARGET_CATALOG, TARGET_SCHEMA=$TARGET_SCHEMA"
  echo "       VS_INDEX_BASE_TABLE=$VS_INDEX_BASE_TABLE, VS_INDEX=$VS_INDEX"
  echo ""
  echo "  2. tool_uc_functions"
  echo "     - Creates UC SQL functions (get_shipments, get_supplier_details, etc.)"
  echo "     - Parameters: TARGET_CATALOG=$TARGET_CATALOG, TARGET_SCHEMA=$TARGET_SCHEMA"
  echo ""
  echo "  3. agent_eval_notebook"
  echo "     - Logs agent to MLflow, registers in Unity Catalog, deploys to Model Serving"
  echo "     - Runs evaluation with LLM judges"
  echo "     - Note: Vector search index will be created automatically if needed"
  echo ""
  echo "After running the notebooks, deploy the chat app with:"
  echo "  databricks bundle deploy --target dev"
  echo "  databricks bundle run weatherwise_chatapp"
  echo "============================================================"
}

# ── Find or create SQL warehouse for Dashboard & Genie ──────
setup_sql_warehouse() {
  echo ""
  echo "Setting up SQL warehouse..."

  if [[ -n "${DATABRICKS_SQL_WAREHOUSE_ID:-}" ]]; then
    echo "  Using configured warehouse: $DATABRICKS_SQL_WAREHOUSE_ID"
  else
    # Find an existing warehouse (prefer serverless)
    DATABRICKS_SQL_WAREHOUSE_ID=$(databricks warehouses list --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
warehouses = data if isinstance(data, list) else data.get('warehouses', [])
for w in warehouses:
    wtype = w.get('warehouse_type', '')
    if wtype == 'PRO' and w.get('enable_serverless_compute', False):
        print(w['id'])
        break
else:
    for w in warehouses:
        print(w['id'])
        break
" 2>/dev/null || echo "")

    if [[ -z "$DATABRICKS_SQL_WAREHOUSE_ID" ]]; then
      echo "  No warehouse found. Creating a serverless warehouse..."
      DATABRICKS_SQL_WAREHOUSE_ID=$(databricks warehouses create --json "{
        \"name\": \"weatherwise-dashboard\",
        \"cluster_size\": \"2X-Small\",
        \"warehouse_type\": \"PRO\",
        \"enable_serverless_compute\": true,
        \"auto_stop_mins\": 10,
        \"max_num_clusters\": 1
      }" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

      if [[ -z "$DATABRICKS_SQL_WAREHOUSE_ID" ]]; then
        echo "  WARNING: Could not create SQL warehouse. Dashboard and Genie will not work."
        echo "  Set DATABRICKS_SQL_WAREHOUSE_ID in .env manually."
        return
      fi
      echo "  Created warehouse: weatherwise-dashboard ($DATABRICKS_SQL_WAREHOUSE_ID)"
    else
      local wname
      wname=$(databricks warehouses get "$DATABRICKS_SQL_WAREHOUSE_ID" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
      echo "  Found warehouse: $wname ($DATABRICKS_SQL_WAREHOUSE_ID)"
    fi
  fi

  # Persist to .env if not already there
  local env_file="$SCRIPT_DIR/.env"
  [[ ! -f "$env_file" ]] && env_file="$SCRIPT_DIR/_env"
  if grep -q "^DATABRICKS_SQL_WAREHOUSE_ID=" "$env_file" 2>/dev/null; then
    # Update existing value
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s/^DATABRICKS_SQL_WAREHOUSE_ID=.*/DATABRICKS_SQL_WAREHOUSE_ID=$DATABRICKS_SQL_WAREHOUSE_ID/" "$env_file"
    else
      sed -i "s/^DATABRICKS_SQL_WAREHOUSE_ID=.*/DATABRICKS_SQL_WAREHOUSE_ID=$DATABRICKS_SQL_WAREHOUSE_ID/" "$env_file"
    fi
  else
    echo "" >> "$env_file"
    echo "# SQL Warehouse for Dashboard and Genie" >> "$env_file"
    echo "DATABRICKS_SQL_WAREHOUSE_ID=$DATABRICKS_SQL_WAREHOUSE_ID" >> "$env_file"
    echo "  (Appended DATABRICKS_SQL_WAREHOUSE_ID to $env_file)"
  fi

  # Grant permissions to app service principal (if app exists)
  local app_sp_id
  app_sp_id=$(databricks apps get weatherwise-chat-agent --output json 2>/dev/null | python3 -c "
import sys, json
app = json.load(sys.stdin)
sp = app.get('service_principal', {})
print(sp.get('id', sp.get('application_id', '')))
" 2>/dev/null || echo "")

  if [[ -n "$app_sp_id" ]]; then
    echo "  Granting CAN_USE on warehouse to app service principal..."
    databricks api patch "/api/2.0/permissions/warehouses/$DATABRICKS_SQL_WAREHOUSE_ID" --json "{
      \"access_control_list\": [
        {
          \"service_principal_name\": \"$app_sp_id\",
          \"all_permissions\": [
            { \"permission_level\": \"CAN_USE\" }
          ]
        }
      ]
    }" 2>/dev/null && echo "    Warehouse permission granted." || echo "    NOTE: Warehouse permission will be granted via bundle deploy."

    # Grant Unity Catalog permissions using SP client ID
    local app_sp_client_id
    app_sp_client_id=$(databricks apps get weatherwise-chat-agent --output json 2>/dev/null | python3 -c "
import sys, json
print(json.load(sys.stdin).get('service_principal_client_id', ''))
" 2>/dev/null || echo "")

    if [[ -n "$app_sp_client_id" ]]; then
      echo "  Granting Unity Catalog permissions to SP ($app_sp_client_id)..."
      for grant in \
        "GRANT USE CATALOG ON CATALOG $TARGET_CATALOG TO \`$app_sp_client_id\`" \
        "GRANT USE SCHEMA ON SCHEMA $TARGET_CATALOG.$TARGET_SCHEMA TO \`$app_sp_client_id\`" \
        "GRANT SELECT ON SCHEMA $TARGET_CATALOG.$TARGET_SCHEMA TO \`$app_sp_client_id\`"; do
        databricks api post /api/2.0/sql/statements --json "{
          \"warehouse_id\": \"$DATABRICKS_SQL_WAREHOUSE_ID\",
          \"statement\": \"$grant\",
          \"wait_timeout\": \"30s\"
        }" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
state = d.get('status',{}).get('state','')
if state == 'SUCCEEDED':
    print('    OK: $grant'.split(' TO ')[0] + '...granted')
else:
    err = d.get('status',{}).get('error',{}).get('message','unknown')
    print(f'    WARN: {err}')
" 2>/dev/null
      done
    fi
  else
    echo "  App not yet deployed — permissions will be set on next run after deploy."
  fi
}

# ── Create Genie Space ──────────────────────────────────────
create_genie_space() {
  if [[ -z "${DATABRICKS_SQL_WAREHOUSE_ID:-}" ]]; then
    echo ""
    echo "  Skipping Genie Space creation (no SQL warehouse available)."
    return
  fi

  if [[ -n "${DATABRICKS_GENIE_SPACE_ID:-}" ]]; then
    echo ""
    echo "  Genie Space already configured: $DATABRICKS_GENIE_SPACE_ID"
    return
  fi

  echo ""
  echo "Creating Genie Space for $TARGET_CATALOG.$TARGET_SCHEMA..."

  local space_id
  # Use Python to construct the payload (tables must be sorted by identifier)
  space_id=$(python3 -c "
import json, urllib.request, ssl, subprocess

token_data = json.loads(subprocess.run(['databricks', 'auth', 'token'], capture_output=True, text=True).stdout)
token = token_data['access_token']

host_result = subprocess.run(['databricks', 'auth', 'describe', '--output', 'json'], capture_output=True, text=True)
# Fall back to env
import os
host = os.environ.get('DATABRICKS_HOST', '').rstrip('/')
if not host:
    import configparser
    cfg = configparser.ConfigParser()
    cfg.read(os.path.expanduser('~/.databrickscfg'))
    host = cfg.get('DEFAULT', 'host', fallback='').rstrip('/')

cat = '$TARGET_CATALOG'
schema = '$TARGET_SCHEMA'
wh = '$DATABRICKS_SQL_WAREHOUSE_ID'

tables = sorted([
    {'identifier': f'{cat}.{schema}.inventory'},
    {'identifier': f'{cat}.{schema}.shipments'},
    {'identifier': f'{cat}.{schema}.supplier_sops'},
    {'identifier': f'{cat}.{schema}.suppliers'},
], key=lambda t: t['identifier'])

serialized = json.dumps({'version': 2, 'data_sources': {'tables': tables}})
payload = json.dumps({
    'title': 'WeatherWise Supply Chain Explorer',
    'description': 'Ask natural language questions about shipments, inventory, suppliers, and SOPs for Jackson & Jackson MedTech.',
    'warehouse_id': wh,
    'serialized_space': serialized
}).encode()

req = urllib.request.Request(f'{host}/api/2.0/genie/spaces', data=payload,
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}, method='POST')
try:
    resp = urllib.request.urlopen(req, context=ssl.create_default_context())
    result = json.loads(resp.read())
    print(result.get('space_id', ''))
except Exception as e:
    import sys; print('', file=sys.stderr); print(str(e), file=sys.stderr)
" 2>/dev/null)

  if [[ -z "$space_id" ]]; then
    echo "  WARNING: Failed to create Genie Space."
    echo "  You can create one manually or run: ./genie/setup_genie_space.sh"
    return
  fi

  echo "  Genie Space created: $space_id"

  # Append to .env if not already there
  local env_file="$SCRIPT_DIR/.env"
  [[ ! -f "$env_file" ]] && env_file="$SCRIPT_DIR/_env"
  if ! grep -q "DATABRICKS_GENIE_SPACE_ID" "$env_file" 2>/dev/null; then
    echo "" >> "$env_file"
    echo "# Genie Space for Ask Genie tab" >> "$env_file"
    echo "DATABRICKS_GENIE_SPACE_ID=$space_id" >> "$env_file"
    echo "  (Appended DATABRICKS_GENIE_SPACE_ID to $env_file)"
  fi
}

# ── Set app thumbnail ─────────────────────────────────────────
set_app_thumbnail() {
  local app_name="${APP_NAME:-weatherwise-chat-agent}"
  local image="$SCRIPT_DIR/img/10_app_dashboard.png"

  if [[ ! -f "$image" ]]; then
    echo "  Skipping thumbnail — image not found: $image"
    return
  fi

  echo ""
  echo "Setting app thumbnail for $app_name..."

  # Resize to 640x360 (max 250KB) if needed
  local upload_image="$image"
  if python3 -c "
from PIL import Image
img = Image.open('$image')
exit(0 if img.size != (640, 360) or __import__('os').path.getsize('$image') > 250*1024 else 1)
" 2>/dev/null; then
    upload_image="/tmp/app_thumbnail_resized.png"
    python3 -c "
from PIL import Image
Image.open('$image').resize((640, 360), Image.LANCZOS).save('$upload_image', optimize=True)
"
    echo "  Resized to 640x360"
  fi

  local token host encoded
  host=$(python3 -c "
import configparser, os
cfg = configparser.ConfigParser()
cfg.read(os.path.expanduser('~/.databrickscfg'))
print(cfg.get('DEFAULT', 'host', fallback='').rstrip('/'))
")
  token=$(databricks auth token --host "$host" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  encoded=$(base64 -i "$upload_image")

  local result error
  result=$(curl -s -X POST "$host/api/2.0/apps/$app_name/thumbnail" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"encoded_thumbnail\": \"$encoded\"}")

  error=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error_code',''))" 2>/dev/null || echo "")
  if [[ -n "$error" ]]; then
    echo "  WARNING: Failed to set thumbnail — $error"
  else
    echo "  Thumbnail set successfully."
  fi
}

# ── Main ─────────────────────────────────────────────────────
main() {
  echo "============================================================"
  echo "  WeatherWise Agent Demo - Setup"
  echo "============================================================"

  load_env
  check_prerequisites
  resolve_cluster
  import_notebooks

  if [[ "$MANUAL_MODE" == "true" ]]; then
    print_manual_instructions
    exit 0
  fi

  # Run notebooks in order
  local setup_params="{
    \"TARGET_CATALOG\": \"$TARGET_CATALOG\",
    \"TARGET_SCHEMA\": \"$TARGET_SCHEMA\",
    \"VS_INDEX_BASE_TABLE\": \"$VS_INDEX_BASE_TABLE\",
    \"VS_INDEX\": \"$VS_INDEX\"
  }"

  local uc_params="{
    \"TARGET_CATALOG\": \"$TARGET_CATALOG\",
    \"TARGET_SCHEMA\": \"$TARGET_SCHEMA\"
  }"

  if ! run_notebook "$WORKSPACE_SETUP_PATH/setup_data" "setup_data" "$setup_params"; then
    echo ""
    echo "Setup data failed. Fix the issue and re-run, or use --manual mode."
    exit 1
  fi

  if ! run_notebook "$WORKSPACE_SETUP_PATH/tool_uc_functions" "tool_uc_functions" "$uc_params"; then
    echo ""
    echo "UC functions setup failed. Fix the issue and re-run, or use --manual mode."
    exit 1
  fi

  # Create vector search index via API
  create_vector_search_index

  # Set up SQL warehouse (find/create, persist, grant permissions)
  setup_sql_warehouse

  # Create Genie Space for Ask Genie tab
  create_genie_space

  # Run agent eval notebook (logs, registers, and deploys the agent)
  local agent_params="{
    \"TARGET_CATALOG\": \"$TARGET_CATALOG\",
    \"TARGET_SCHEMA\": \"$TARGET_SCHEMA\",
    \"VS_INDEX\": \"${VS_INDEX:-}\",
    \"DATABRICKS_HOST\": \"${DATABRICKS_HOST:-}\",
    \"AI_GATEWAY_MODEL\": \"${AI_GATEWAY_MODEL:-}\",
    \"AI_GATEWAY_BASE_URL\": \"${AI_GATEWAY_BASE_URL:-}\",
    \"MLFLOW_EXPERIMENT\": \"${MLFLOW_EXPERIMENT:-}\",
    \"RETRIEVER_TOOL_NAME\": \"${RETRIEVER_TOOL_NAME:-}\",
    \"AGENT_NAME\": \"${AGENT_NAME:-}\"
  }"

  if ! run_notebook "$WORKSPACE_SETUP_PATH/agent_eval_notebook" "agent_eval_notebook" "$agent_params"; then
    echo ""
    echo "Agent evaluation/deployment failed. Fix the issue and re-run, or use --manual mode."
    exit 1
  fi

  echo ""
  echo "============================================================"
  echo "  Setup Complete!"
  echo "============================================================"
  echo ""
  echo "  Catalog:      $TARGET_CATALOG"
  echo "  Schema:       $TARGET_SCHEMA"
  echo "  Tables:       shipments, suppliers, inventory, $VS_INDEX_BASE_TABLE"
  echo "  Functions:    get_shipments, get_supplier_details, get_backup_inventory, temp_gap"
  echo "  VS Index:     $TARGET_CATALOG.$TARGET_SCHEMA.$VS_INDEX"
  echo "  Agent:        $TARGET_CATALOG.$TARGET_SCHEMA.${AGENT_NAME:-weatherwise_agent}"
  echo "  SQL Warehouse: ${DATABRICKS_SQL_WAREHOUSE_ID:-not configured}"
  echo "  Genie Space:  ${DATABRICKS_GENIE_SPACE_ID:-not created}"
  echo ""
  # Set app thumbnail
  set_app_thumbnail

  echo "Next steps:"
  echo "  Deploy the chat app:"
  echo "    databricks bundle deploy --target dev"
  echo "    databricks bundle run weatherwise_chatapp"
  echo ""
}

main
